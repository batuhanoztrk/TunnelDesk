# TunnelDesk

Kubernetes ve SSH tünellerini tek ekranda yönetmek için küçük, bağımsız bir macOS uygulaması. Swift ve SwiftUI ile geliştirilmiştir. Otomatik güncellemeler için Sparkle uygulamaya dahil edilmiştir.

Uygulama boş başlar. Hazır bağlantı, kubeconfig, context, namespace veya sunucu bilgisi içermez.

## Özellikler

- Birden fazla tüneli aynı anda çalıştırma; ayrı ayrı veya topluca açma ve kapatma.
- Bağlantı profili oluşturma, düzenleme, çoğaltma ve silme.
- Menü çubuğundan kontrol, bağlantı durumu ve günlükler.
- Port çakışması kontrolü ve görünür hata mesajları.
- GitHub release'lerinden imzalı otomatik güncelleme; menüden elle kontrol ve otomatik güncelleme ayarları.
- Ayarlar → Genel'den Dock ve menü çubuğu simgelerini ayrı ayrı yönetme; varsayılan Dock kapalı, tray açık.
- Yerel dinleyicileri yalnızca `127.0.0.1` adresine bağlama.

| Tür | Kullanım |
| --- | --- |
| Kubernetes TCP tüneli | Cluster'ın erişebildiği bir sunucuya geçici `socat` podu üzerinden erişim. |
| Kubernetes port yönlendirme | Var olan `pod`, `service` veya `deployment` kaynağına yönlendirme. |
| SSH yerel tüneli | SSH sunucusunun erişebildiği hedef sunucu ve porta yönlendirme. |

TCP tüneli için oluşturulan pod, tünel kapatıldığında temizlenir. SSH bağlantıları agent, SSH config veya anahtar dosyası kullanır; etkileşimli şifre girişi desteklenmez.

## Gereksinimler

- macOS 14 veya üzeri.
- Kubernetes bağlantıları için `kubectl`, erişilebilir bir kubeconfig ve gerekli namespace yetkileri.
- TCP tünellerinde cluster'ın `alpine/socat` imajını çekebilmesi ve hedef sunucuya erişebilmesi.
- SSH bağlantıları için sistemin `ssh` aracı ve önceden doğrulanmış host anahtarı.
- Derleme için Xcode veya Apple Command Line Tools.

## Derleme

```bash
bash build.sh
open TunnelDesk.app
```

Derleme, mevcut Mac'in mimarisine uygun ve yerel olarak imzalanmış `TunnelDesk.app` oluşturur. Uygulamayı Applications klasörüne taşıyabilirsin.

İlk derleme, SHA-256 değeri sabitlenmiş resmi Sparkle paketini indirir; internet erişimi gerekir. Sparkle uygulamanın içinde taşınır, kullanıcıların ayrıca kurması gerekmez. Lisans: [LICENSES/Sparkle.txt](LICENSES/Sparkle.txt).

## Dock ve menü çubuğu

Uygulama varsayılan olarak Dock'ta görünmez; menü çubuğundaki TunnelDesk simgesinden ulaşılır. **Ayarlar → Genel** bölümündeki **Dock'ta göster** ve **Menü çubuğunda (tray) göster** seçenekleri anında uygulanır ve hatırlanır. Uygulamaya erişim kaybolmasın diye ikisi aynı anda kapalı tutulmaz; son simgeyi kapatırken diğeri otomatik açılır.

Tray menüsünden tünelleri tek tek veya topluca açıp kapatabilir, ana pencereyi ve Ayarlar'ı açabilirsin. Pencereyi kapatmak uygulamayı veya açık tünelleri durdurmaz. Tamamen çıkmak için tray menüsündeki **Çıkış** seçeneğini kullan.

## Güncellemeler

**TunnelDesk → Güncellemeleri kontrol et…** veya menü çubuğundaki aynı komutla yeni sürümü kontrol edebilirsin. Varsayılan olarak uygulama 6 saatte bir kontrol eder, güncellemeyi arka planda indirir ve uygulama kapanırken kurar. Ayarlar'dan otomatik kontrolü ve indirmeyi değiştirebilirsin. Elle başlatılan kurulumda uygulama tünelleri temizleyip yeniden başlar.

Güncellemeler public GitHub release'lerindeki imzalı `appcast.xml` üzerinden bulunur. Hem metadata hem ZIP Ed25519 ile doğrulanır. GitHub hesabı, token veya `gh` kurulumu gerekmez. Uygulama verileri ve içeri aktarılan kubeconfig dosyaları korunur. 1.0.1 ve önceki sürümlerden geçerken güncelleme altyapısını içeren sürümü bir kez elle kurmak gerekir.

Yeni sürüm yayımlama: [docs/releases.md](docs/releases.md).

## Yerel doğrulama

```bash
bash test.sh
```

Entegrasyon kontrolleri sahte `kubectl` / SSH süreçleri ve yerel soketler kullanır; gerçek cluster veya SSH sunucusuna bağlanmaz. Eşzamanlı bağlantı, iptal, port çakışması, pod sahipliği, temizleme hataları ve uygulama çıkışındaki süreç temizliği kontrol edilir.

## Kayıtlar

Profiller `~/Library/Application Support/TunnelDesk/profiles.json` dosyasında tutulur. Bağlantıyı kaydederken kubeconfig, `~/Library/Application Support/TunnelDesk/kubeconfigs/` klasörüne içeri aktarılır; bağlantı bu kopyayı kullanır. Orijinal kubeconfig dosyasını silebilir veya taşıyabilirsin.

Sertifika, anahtar ve token dosyalarına referanslar kopyanın içine alınır. Kubeconfig kopyaları yalnızca mevcut kullanıcının okuyup yazabileceği izinlerle saklanır. Dosya içeriği günlüklere yazılmaz. Yeni bir kubeconfig ile güncellemek için bağlantıyı düzenleyip yeni dosyayı seçerek kaydet; orijinal dosyadaki sonraki değişiklikler otomatik olarak kopyaya aktarılmaz.

Eski sürümde oluşturulmuş bağlantılar ilk açılışta otomatik olarak içeri aktarılır. Orijinal dosya önceden silinmişse uygulama durumu bildirir; bağlantıyı düzenleyip dosyayı yeniden seçmek gerekir. Bağlantı silindiğinde kullanılmayan uygulama kopyası da temizlenir.

SSH anahtar dosyalarının yalnızca yolları kaydedilir. Kubeconfig'in kullandığı harici kimlik doğrulama araçları kurulu kalmalıdır. Veritabanı kullanıcı adı ve şifresi uygulamaya girilmez.

Pencereyi kapatmak tünelleri açık tutar. **Çıkış / Cmd+Q**, yerel tünelleri durdurur ve oluşturulan geçici podları temizler. Uygulama zorla kapatılırsa artık pod kalabilir; geçici podların çalışma süresi en fazla 24 saattir.

Ayrıntılı kullanım ve kısayollar: [KULLANIM.txt](KULLANIM.txt).
