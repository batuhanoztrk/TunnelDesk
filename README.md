# TunnelDesk

Kubernetes ve SSH tünellerini tek ekranda yönetmek için küçük, bağımsız bir macOS uygulaması. Swift ve SwiftUI ile geliştirilmiştir; üçüncü taraf uygulama bağımlılığı yoktur.

Uygulama boş başlar. Hazır bağlantı, kubeconfig, context, namespace veya sunucu bilgisi içermez.

## Özellikler

- Birden fazla tüneli aynı anda çalıştırma; ayrı ayrı veya topluca açma ve kapatma.
- Bağlantı profili oluşturma, düzenleme, çoğaltma ve silme.
- Menü çubuğundan kontrol, bağlantı durumu ve günlükler.
- Port çakışması kontrolü ve görünür hata mesajları.
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

## Yerel doğrulama

```bash
bash test.sh
```

Entegrasyon kontrolleri sahte `kubectl` / SSH süreçleri ve yerel soketler kullanır; gerçek cluster veya SSH sunucusuna bağlanmaz. Eşzamanlı bağlantı, iptal, port çakışması, pod sahipliği, temizleme hataları ve uygulama çıkışındaki süreç temizliği kontrol edilir.

## Kayıtlar

Profiller `~/Library/Application Support/TunnelDesk/profiles.json` dosyasında tutulur. Kubeconfig ve SSH anahtar dosyalarının yalnızca yolları kaydedilir; içerikleri kopyalanmaz. Veritabanı kullanıcı adı ve şifresi uygulamaya girilmez.

Pencereyi kapatmak tünelleri açık tutar. **Çıkış / Cmd+Q**, yerel tünelleri durdurur ve oluşturulan geçici podları temizler. Uygulama zorla kapatılırsa artık pod kalabilir; geçici podların çalışma süresi en fazla 24 saattir.

Ayrıntılı kullanım ve kısayollar: [KULLANIM.txt](KULLANIM.txt).
