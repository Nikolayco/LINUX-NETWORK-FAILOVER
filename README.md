🌐 Universal Linux Network Failover Script (v1.0)
Linux cihazlarınızda (Laptop, Sunucu, Raspberry Pi) kesintisiz internet bağlantısı sağlamak için geliştirilmiş, otomatik ağ yedekleme (failover) scripti.

Bu script; Ethernet, Dahili WiFi, USB WiFi, 4G Modemler ve Android USB Tethering cihazlarını otomatik olarak tanır, önceliklendirir ve ana internet kesildiğinde saniyeler içinde yedek hatta geçiş yapar. İnternet geri geldiğinde ise otomatik olarak ana hatta döner (Failback).

<img width="659" height="212" alt="image" src="https://github.com/user-attachments/assets/1afe3f47-2a1f-4525-a12a-3989ec60840f" />


🚀 Özellikler
Evrensel Donanım Desteği: Marka/Model bağımsızdır. eth0, wlan0 gibi isimlere takılmaz; donanım türünü (Kablolu, Kablosuz, USB) otomatik analiz eder.

Akıllı Önceliklendirme (Smart Priority): Hangi bağlantının "daha değerli" olduğunu bilir.

Ethernet (Fiber/Kablo) > Dahili WiFi > USB Ethernet / Android Telefon > Harici USB WiFi

Android USB Tethering Desteği: Android telefonunuzu USB ile bağladığınızda otomatik olarak "Yedek Modem" olarak tanır.

Ceza Sistemi (Penalty Logic): Bağlantısı kopan (ama kablosu takılı olan) hattı tespit eder, puanını düşürür ve sistemi o hatla vakit kaybetmekten kurtarır.

Servis Modu: Arka planda sessizce çalışır (Systemd Service), bilgisayar yeniden başladığında otomatik devreye girer.

Canlı İzleme (Monitor Mode): Hangi hattın aktif olduğunu, ping sürelerini ve geçiş anlarını terminalden canlı izlemenizi sağlar.

<img width="505" height="544" alt="image" src="https://github.com/user-attachments/assets/1d4edba6-418c-428a-8431-0215f63e6435" />


📊 Öncelik Sıralaması (Metrikler)
Script, Linux routing tablosunda aşağıdaki Metrik değerlerini kullanır (Düşük puan = Yüksek Öncelik):

Kablolu Ethernet: 100 (En Yüksek Öncelik - Ana Hat)

Dahili WiFi (PCIe): 110 (Güçlü Yedek)

USB Ethernet / Android Tethering: 200 (Mobil Yedek)

Harici USB WiFi: 300 (Son Çare)

Diğer Modemler (3G/4G Dongle): 400

Örnek: Ethernet kablosu takılıyken (100), WiFi (110) bağlı olsa bile sistem Ethernet'i kullanır. Kablo çekilirse otomatik olarak WiFi'ye geçer.

📥 Kurulum
Scripti indirin ve çalıştırılabilir hale getirin:

Bash

# 1.Yöntem:
# Aşağıdaki satırı kopyalayarak terminale yapıştırın ve çalıştırın.
wget -qO /tmp/linux-failover.sh https://raw.githubusercontent.com/Nikolayco/LINUX-NETWORK-FAILOVER/main/linux-universal-network-failover.sh && sudo bash /tmp/linux-failover.sh

# 2.Yöntem:
# Scripti indirin (Raw linki kullanın)
wget https://raw.githubusercontent.com/Nikolayco/LINUX-NETWORK-FAILOVER/main/linux-universal-network-failover.sh

# Çalıştırma izni verin
chmod +x linux-universal-network-failover.sh

# Çalıştırın
sudo ./linux-universal-network-failover.sh
it 🛠️ Kullanım
Scripti çalıştırdığınızda karşınıza interaktif bir menü gelir:

Install Service (Kur): Scripti sisteme bir servis olarak kurar. Bilgisayar açılınca otomatik başlar. (Tavsiye edilen).

Monitor Mode (Canlı İzle): O anki durumu, hangi hatların bağlı olduğunu ve internet testlerini canlı gösterir. Test yapmak için idealdir.

Uninstall (Kaldır): Servisi durdurur ve sistemden temizler.

Manuel Test Nasıl Yapılır?
Scripti çalıştırın ve 2 (Monitor Mode) seçeneğini seçin.

Bilgisayarınızın Ethernet kablosunu çekin veya WiFi'yi kapatın.

Ekranda HAT DEĞİŞTİ uyarısını ve yeni hatta geçildiğini gözlemleyin.

📋 Gereksinimler
İşletim Sistemi: Ubuntu, Linux Mint, Debian, Kali Linux, Raspberry Pi OS ve diğer Debian tabanlı dağıtımlar.

Paketler: curl (Genellikle yüklüdür, değilse script uyarır).

Yetki: Ağ ayarlarını değiştirmek için root (sudo) yetkisi gerekir.

⚠️ Uyarılar
Bu script, Linux'un routing tablosunu (ip route) yönetir. VPN kullanıyorsanız (Wireguard, OpenVPN), VPN yazılımınızla çakışmaması için VPN ayarlarınızı kontrol edin.

Script, bağlantı kontrolü için Google DNS (8.8.8.8) ve Cloudflare DNS (1.1.1.1) adreslerine ping atar.



Geliştirici: Nikolayco Lisans: MIT (İstediğiniz gibi kullanabilir ve değiştirebilirsiniz).
