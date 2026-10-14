import base64

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

import sign_lips_release as S


def keypair():
    key = Ed25519PrivateKey.generate()
    private = key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                serialization.NoEncryption())
    public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return base64.b64encode(private).decode(), base64.b64encode(public).decode()


def test_signature_covers_tag_and_sums():
    private, public = keypair()
    sums = b"abc  velikiy-moguchiy-lips-0.2.pt\n"
    sig = S.sign("lips-0.2", sums, private)
    assert S.verify("lips-0.2", sums, sig, public)
    assert not S.verify("lips-0.3", sums, sig, public)
    assert not S.verify("lips-0.2", sums + b"x", sig, public)
    assert not S.verify("lips-0.2", sums, sig, keypair()[1])


def test_message_matches_the_app():
    # SPLipsRuntimePolicyTests.testSignedMessageAndWhichReleasesNeedASignature builds the same bytes.
    assert S.message("lips-0.2", b"abc  f.pt\n") == b"velikiy-moguchiy/lips-release/v1\nlips-0.2\nabc  f.pt\n"
