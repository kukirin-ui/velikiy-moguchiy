//! Connecting a WebSocket without waiting on a dead IP family.
//!
//! On networks whose IPv6 route is broken, `connect_async` resolves the host and
//! tries the first address (often an AAAA) until the OS gives up, so the whole
//! connect budget is spent before IPv4 is even attempted. Here the addresses are
//! ordered IPv4-first with the families interleaved, and the TCP attempts are
//! raced Happy-Eyeballs style: a new attempt starts every `stagger`, or at once
//! when the previous one fails, and the first connection to succeed wins.
//! Behaviour specified by OpenLess af9eaa3 (AGPL-3.0, used as a specification
//! only); the implementation is our own.

use std::collections::VecDeque;
use std::io;
use std::net::SocketAddr;

use futures_util::stream::{FuturesUnordered, StreamExt};
use tokio::net::{lookup_host, TcpStream};
use tokio::time::{timeout, Duration};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::handshake::client::Response;
use tokio_tungstenite::tungstenite::http::Request;
use tokio_tungstenite::{client_async_tls_with_config, MaybeTlsStream, WebSocketStream};

/// Delay before the next address is tried while earlier attempts are pending.
pub const ATTEMPT_STAGGER: Duration = Duration::from_millis(300);
/// Upper bound for one TCP attempt when several addresses are available. A lone
/// address gets the caller's overall budget instead.
pub const PER_ADDRESS_TIMEOUT: Duration = Duration::from_millis(1500);

/// IPv4 first, families interleaved (v4, v6, v4, v6, ...), duplicates dropped.
/// Interleaving keeps a second address of the preferred family from delaying the
/// first one of the other family when the preferred family is the broken one.
pub fn order_addresses(addrs: impl IntoIterator<Item = SocketAddr>) -> Vec<SocketAddr> {
    let mut v4: VecDeque<SocketAddr> = VecDeque::new();
    let mut v6: VecDeque<SocketAddr> = VecDeque::new();
    for addr in addrs {
        let bucket = if addr.is_ipv4() { &mut v4 } else { &mut v6 };
        if !bucket.contains(&addr) {
            bucket.push_back(addr);
        }
    }
    let mut ordered = Vec::with_capacity(v4.len() + v6.len());
    loop {
        match (v4.pop_front(), v6.pop_front()) {
            (None, None) => break,
            (a, b) => ordered.extend(a.into_iter().chain(b)),
        }
    }
    ordered
}

/// Host and port a WebSocket request points at, with the scheme's default port.
pub fn request_endpoint<T>(request: &Request<T>) -> io::Result<(String, u16)> {
    let uri = request.uri();
    let default_port = match uri.scheme_str() {
        Some("wss") => 443,
        Some("ws") => 80,
        other => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("unsupported WebSocket scheme: {other:?}"),
            ))
        }
    };
    let host = uri
        .host()
        .map(|h| h.trim_start_matches('[').trim_end_matches(']').to_string())
        .filter(|h| !h.is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "request has no host"))?;
    Ok((host, uri.port_u16().unwrap_or(default_port)))
}

async fn tcp_attempt(addr: SocketAddr, cap: Option<Duration>) -> io::Result<TcpStream> {
    match cap {
        Some(cap) => match timeout(cap, TcpStream::connect(addr)).await {
            Ok(result) => result,
            Err(_) => Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!(
                    "tcp connect to {} ({}) timed out",
                    addr.ip(),
                    if addr.is_ipv4() { "v4" } else { "v6" }
                ),
            )),
        },
        None => TcpStream::connect(addr).await,
    }
}

/// Race TCP connects to `addrs` (already ordered), starting a new one every
/// `stagger` or immediately after a failure; returns the first that connects.
pub async fn connect_staggered(
    addrs: Vec<SocketAddr>,
    stagger: Duration,
    per_address: Duration,
) -> io::Result<TcpStream> {
    let cap = (addrs.len() > 1).then_some(per_address);
    let mut queue: VecDeque<SocketAddr> = addrs.into();
    let mut attempts = FuturesUnordered::new();
    let mut last_error = None;
    loop {
        if let Some(addr) = queue.pop_front() {
            attempts.push(tcp_attempt(addr, cap));
        }
        if attempts.is_empty() {
            break;
        }
        let outcome = if queue.is_empty() {
            // Nothing left to start: wait for the in-flight attempts.
            Ok(attempts.next().await)
        } else {
            timeout(stagger, attempts.next()).await
        };
        match outcome {
            Ok(Some(Ok(stream))) => return Ok(stream),
            Ok(Some(Err(error))) => last_error = Some(error),
            // Stagger elapsed with attempts still running: start the next address.
            Ok(None) | Err(_) => {}
        }
    }
    Err(last_error.unwrap_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, "no addresses for the endpoint")
    }))
}

/// Resolve the request's host, connect over the fastest working address, then do
/// the TLS (for `wss`) and WebSocket handshakes on that stream.
pub async fn connect_websocket<T>(
    request: Request<T>,
) -> Result<
    (
        WebSocketStream<MaybeTlsStream<TcpStream>>,
        Response,
    ),
    tokio_tungstenite::tungstenite::Error,
>
where
    Request<T>: IntoClientRequest,
{
    use tokio_tungstenite::tungstenite::Error as WsError;
    let request = request.into_client_request()?;
    let (host, port) = request_endpoint(&request).map_err(WsError::Io)?;
    let resolved: Vec<SocketAddr> = lookup_host((host.as_str(), port))
        .await
        .map_err(WsError::Io)?
        .collect();
    let stream = connect_staggered(order_addresses(resolved), ATTEMPT_STAGGER, PER_ADDRESS_TIMEOUT)
        .await
        .map_err(WsError::Io)?;
    client_async_tls_with_config(request, stream, None, None).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn addr(s: &str) -> SocketAddr {
        s.parse().unwrap()
    }

    #[test]
    fn ipv4_goes_first_and_families_interleave() {
        let ordered = order_addresses([
            addr("[2408:400a::1]:443"),
            addr("[2408:400a::2]:443"),
            addr("8.152.159.24:443"),
            addr("8.152.159.25:443"),
        ]);
        assert_eq!(
            ordered,
            vec![
                addr("8.152.159.24:443"),
                addr("[2408:400a::1]:443"),
                addr("8.152.159.25:443"),
                addr("[2408:400a::2]:443"),
            ]
        );
    }

    #[test]
    fn ordering_drops_duplicates_and_keeps_a_single_family() {
        assert_eq!(
            order_addresses([addr("1.1.1.1:443"), addr("1.1.1.1:443")]),
            vec![addr("1.1.1.1:443")]
        );
        assert_eq!(
            order_addresses([addr("[::1]:443"), addr("[::2]:443")]),
            vec![addr("[::1]:443"), addr("[::2]:443")]
        );
        assert!(order_addresses([]).is_empty());
    }

    #[test]
    fn endpoint_uses_the_scheme_default_port() {
        let wss = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
            .into_client_request()
            .unwrap();
        assert_eq!(
            request_endpoint(&wss).unwrap(),
            ("dashscope.aliyuncs.com".to_string(), 443)
        );
        let ws = "ws://localhost:9000/x".into_client_request().unwrap();
        assert_eq!(request_endpoint(&ws).unwrap(), ("localhost".to_string(), 9000));
        let v6 = "ws://[::1]:8080/x".into_client_request().unwrap();
        assert_eq!(request_endpoint(&v6).unwrap(), ("::1".to_string(), 8080));
        let plain = "ws://localhost/x".into_client_request().unwrap();
        assert_eq!(request_endpoint(&plain).unwrap().1, 80);
    }

    #[test]
    fn endpoint_rejects_non_websocket_schemes() {
        let https = Request::builder().uri("https://example.com/x").body(()).unwrap();
        assert!(request_endpoint(&https).is_err());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn no_addresses_fails_at_once() {
        let error = connect_staggered(Vec::new(), ATTEMPT_STAGGER, PER_ADDRESS_TIMEOUT)
            .await
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::NotFound);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn a_refused_address_falls_through_to_the_next_without_waiting() {
        // A closed port refuses at once; the listening one must be used without
        // sitting out the stagger.
        let closed = {
            let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            l.local_addr().unwrap()
        };
        let open = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let open_addr = open.local_addr().unwrap();
        let started = std::time::Instant::now();
        let stream = connect_staggered(
            vec![closed, open_addr],
            Duration::from_secs(5),
            Duration::from_secs(5),
        )
        .await
        .unwrap();
        assert_eq!(stream.peer_addr().unwrap(), open_addr);
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn websocket_handshake_runs_over_the_chosen_stream() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            tokio_tungstenite::accept_async(stream).await.unwrap();
        });
        let request = format!("ws://127.0.0.1:{}/path", addr.port())
            .into_client_request()
            .unwrap();
        let (ws, response) = connect_websocket(request).await.unwrap();
        assert_eq!(response.status().as_u16(), 101);
        drop(ws);
        server.await.unwrap();
    }
}
