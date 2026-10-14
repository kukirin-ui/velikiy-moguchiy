cask "velikiy-moguchiy" do
  # .github/workflows/stores.yml writes both on each published release; until then the checksum is zeros
  # on purpose, so an install fails instead of trusting an unknown file.
  version "0.1.0"
  sha256 "f4dd11a212b56d1984b975a00740f2fe2c1deac0b1b3211c52f8690feb8c17e7"

  url "https://github.com/zigansh1n/velikiy-moguchiy/releases/download/v#{version}/VelikiyMoguchiy-macOS-arm64.zip"
  name "Великий & Могучий"
  name "Velikiy Moguchiy"
  desc "Русская голосовая диктовка в любом приложении"
  homepage "https://github.com/zigansh1n/velikiy-moguchiy"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "VelikiyMoguchiy.app"

  # The build has only an ad-hoc signature, so Gatekeeper would refuse to open it.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/VelikiyMoguchiy.app"]
  end

  caveats <<~EOS
    Сборка не подписана сертификатом Apple (только ad-hoc подпись).
    При первом запуске дайте доступ к микрофону, универсальному доступу и мониторингу ввода
    в «Системные настройки → Конфиденциальность и безопасность».
    После каждого обновления macOS может снова спросить эти разрешения или считать их выданными
    старой версии: снимите и заново поставьте галочки.
  EOS
end
