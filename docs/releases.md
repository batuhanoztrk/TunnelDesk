# Sürüm yayımlama

Uygulama güncellemeleri public GitHub release'lerinin `appcast.xml` dosyasından kontrol eder. ZIP dosyası ve bu XML, Sparkle'ın Ed25519 anahtarıyla imzalanır. İmzalar doğrulanmadan güncelleme kurulmaz.

## İmza anahtarı

Private anahtar macOS login Keychain'de, `tr.tunneldesk.mac.updates` hesabında bulunur. Kaynak kodda yalnızca `Info.plist` içindeki açık anahtar vardır. Private anahtarı repoya veya release'e ekleme. Aynı uygulamanın gelecek güncellemelerinde bu anahtarı kullan; yeni anahtar üretip mevcut açık anahtarın üzerine yazma.

## Adımlar

1. `Info.plist` içindeki `CFBundleShortVersionString` değerini ve artan tam sayı `CFBundleVersion` değerini güncelle.
2. `bash test.sh` ile yerel kontrolleri çalıştır, değişiklikleri commit edip GitHub `main` dalına pushla.
3. Release notlarını bir metin dosyasında hazırla.
4. Aşağıdaki komutu çalıştır:

```bash
bash scripts/publish-release.sh /path/to/release-output /path/to/release-notes.txt
```

Komut uygulamayı derler, ZIP'i ve imzalı `appcast.xml` dosyasını hazırlar, SHA-256 dosyasını oluşturur. Önce draft release'e tüm dosyaları yükler, ardından release'i yayımlayıp latest yapar. Geçerli GitHub `gh` oturumu ve orijinal Keychain imza anahtarı yalnızca sürüm yayımlayan Mac'te gerekir. Uygulamayı kullanan kişilerin `gh` veya GitHub oturumuna ihtiyacı yoktur.

Yalnızca paket hazırlamak için:

```bash
bash scripts/prepare-release.sh /path/to/release-output /path/to/release-notes.txt
```

Sparkle 2.10.1 resmi dağıtımı SHA-256 değeri sabitlenerek indirilir ve uygulamaya eklenir. İlk derleme internet erişimi gerektirir; sonraki derlemelerde doğrulanmış paket önbellekten kullanılır. Güncelleme arşivlerini `ditto` ile paketle; framework symlink'lerini koru.
