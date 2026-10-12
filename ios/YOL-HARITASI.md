# Fenotip iPhone — 400 geliştirme yol haritası

Kullanıcı hedefi (12.10.2026): 20'şerlik paketlerle **en az 400 geliştirme**. İşi Codex yapar, Claude (asıl oturum)
denetler; telefon bağlanınca Claude toplu kurar (Sideloadly, USB). Her paket: 20 madde → derleme yeşil → commit/push.

Madde numarası `iPNNN`. Her paket kendi 20 maddesini aşağıya yazar, bitenleri `[x]` yapar. Madde = kullanıcının
fark edeceği bir iyileştirme ya da somut bir sağlamlık düzeltmesi; "kod düzenleme" tek başına madde sayılmaz.

## Paket temaları

| Paket | Maddeler | Tema |
|---|---|---|
| P01 | iP001–iP020 | Oynatıcı I — dokunma hareketleri, denetimler, süre/bitiş, hata ve yeniden deneme |
| P02 | iP021–iP040 | Oynatıcı II — kilit ekranı/Denetim Merkezi bilgisi, ağ kopması, tampon, sonraki bölüm geri sayımı |
| P03 | iP041–iP060 | Ana sayfa — raf düzeni, vitrin, kişiselleştirme, boş/yükleniyor durumları |
| P04 | iP061–iP080 | Film/dizi detayı — oyuncular, sezon/bölüm, benzerler, paylaş, bilgi düzeni |
| P05 | iP081–iP100 | Arama ve keşif — öneriler, tür sayfaları, süzgeçler, sonuç sıralaması |
| P06 | iP101–iP120 | Canlı TV — yayın akışı (EPG) görünümü, kanal numarası, kategori, favori sıralama |
| P07 | iP121–iP140 | Listem ve izleme geçmişi — geçmiş ekranı, düzenleme, sıralama, toplu işlemler |
| P08 | iP141–iP160 | TV'ye gönder ve kumanda — eşleştirme, durum, kumanda ekranı, hata mesajları |
| P09 | iP161–iP180 | Profil ve ayarlar — profil yönetimi, tercihler, önbellek, hakkında |
| P10 | iP181–iP200 | Performans ve bellek — açılış süresi, katalog ayrıştırma, görsel önbellek, kaydırma |
| P11 | iP201–iP220 | Dayanıklılık — çevrimdışı, sunucu/sağlayıcı hataları, yeniden deneme, kurtarma |
| P12 | iP221–iP240 | Erişilebilirlik — VoiceOver etiketleri, Dynamic Type, kontrast, hareket azaltma |
| P13 | iP241–iP260 | iPad ve yatay düzen — ızgara, yan panel, büyük ekran oynatıcı |
| P14 | iP261–iP280 | Görsel cila — geçişler, iskelet yükleme, haptik, boşluk/tipografi |
| P15 | iP281–iP300 | Bildirimler ve arka plan — yeni bölüm bildirimi (yerel), arka planda yenileme |
| P16 | iP301–iP320 | Çocuk profili ve güvenlik — içerik süzgeci, kilitler, gizlilik |
| P17 | iP321–iP340 | Teşhis ve kalite — hata kayıtları, çökme izi, oturum ölçümleri |
| P18 | iP341–iP360 | Metin ve yerelleştirme — Türkçe metinler, sayı/tarih biçimi, tutarlılık |
| P19 | iP361–iP380 | Kısayollar — ana ekran hızlı eylemleri, Spotlight, Siri/App Intents (eklentisiz) |
| P20 | iP381–iP400 | Son cila ve regresyon turu — bütün akışların gözden geçirilmesi |

## Kısıtlar (her paket için)

- Yalnız `ios/**` (+ bu dosya, `IS-BOLUMU.md` Günlük satırı). Sunucu, site, Android, deploy YOK.
- Mac yok: derleme GitHub Actions `ios-app.yml` ile, ama **herkese açık ayna depoda** (Ahmet1991/fenotip-ios): özel depoda
  işler ödeme sorunu yüzünden başlamıyor. Commit + push → `bash ios/scripts/ayna-guncelle.sh` →
  `gh run list -R Ahmet1991/fenotip-ios --workflow ios-app.yml --limit 1` → `gh run watch <id> -R Ahmet1991/fenotip-ios --exit-status`.
- Uygulama eklentisi (widget, extension) YOK: ücretsiz Apple hesabı her eklenti için ayrı App ID harcar.
- Bilinen tuzaklar: VLC çizim alanı üstünde dokunma algılayıcıları cihazda tetiklenmiyor (touchesBegan/Moved/Ended
  kullan); VLC `stop()` ana iş parçacığında kilitlenebiliyor (`stopPlayerInBackground`); profil durumu PC/TV ile ortak.

## Maddeler

### P01

- [x] iP001 — Sol yarıda dikey kaydırma ile ekran parlaklığı ve ortada yüzde göstergesi; çıkışta eski parlaklığı geri yükle.
- [x] iP002 — Sağ yarıda dikey kaydırma ile gizli MPVolumeView üzerinden sistem sesi ve ortada yüzde göstergesi.
- [x] iP003 — Yatay kaydırma ile hedef süreyi ve +/- farkı önizle; parmak bırakılınca hedefe sar.
- [x] iP004 — Uzun basılı tutarken geçici 2x oynatma; bırakınca önceki hıza dön ve gösterge göster.
- [x] iP005 — Görüntü modunu Sığdır / Doldur / 16:9 / 4:3 döngüsüne genişlet.
- [x] iP006 — Ekran kilidi ekle; kilitliyken yalnız kilit düğmesi dokunmaya açık kalsın.
- [x] iP007 — 15/30/45/60 dakika ve dizi için bölüm sonunda uyku zamanlayıcısı ekle.
- [x] iP008 — Altyazı gecikmesini 0,25 sn adımlarla azalt/artır ve sıfırlama akışına bağla.
- [x] iP009 — Ses gecikmesini 0,25 sn adımlarla azalt/artır ve sıfırlama akışına bağla.
- [x] iP010 — Kalan süre etiketine dokununca "Bitiş HH:mm" görünümüne geçiş ekle.
- [x] iP011 — Devam edilen içerikte 5 sn görünen "Kaldığın yerden devam · Baştan başla" bildirimi ekle.
- [x] iP012 — Oynatma hata ekranına son konumdan açan "Tekrar dene" düğmesi ekle.
- [x] iP013 — Oynatma/ağ hatasında son konumdan bir kez otomatik yeniden bağlanma ekle.
- [x] iP014 — Sarma, ekran kilidi ve hız değişimlerine hafif dokunsal geri bildirim ekle.
- [x] iP015 — Oynatıcıya yatay / serbest döndürme kilidi ekle.
- [x] iP016 — Ayarlar'a cihaz özel 5/10/15/30 sn çift dokunuş sarma seçimi ekle ve göstergede kullan.
- [x] iP017 — Hız menüsüne 0.5x ve 1.75x ekle; profilin mevcut kalıcı oynatma hızı tercihini koru.
- [x] iP018 — Arka plana geçerken ilerlemeyi kaydet; idle timer ve parlaklık durumunu çıkış/arka plan akışında kesin geri al.
- [x] iP019 — Dizi başlığını "S1 B3 · Bölüm adı", canlı başlığını "Program · X dk kaldı" biçiminde göster.
- [x] iP020 — Ses ve altyazı düğmelerinde etkin dil kısaltmasını (ör. EN/TR) göster.

### P02
- [x] iP021 — Kilit ekranı ve Denetim Merkezi için başlık, afiş, süre, konum ve hız bilgisini yayınla.
- [x] iP022 — Kilit ekranından oynat/duraklat, ±10 sn ve konuma git komutlarını işle.
- [x] iP023 — Oynatıcı kapanınca Şimdi Oynatılıyor bilgisini ve uzaktan komut hedeflerini temizle.
- [x] iP024 — Oynatıcıya AirPlay / ses çıkışı seçicisi ekle.
- [x] iP025 — Bölüm sonunda 10 sn Sonraki bölüm geri sayımı, Şimdi oynat ve İptal akışı ekle.
- [x] iP026 — Dizide varsa Önceki bölüm düğmesi ekle.
- [x] iP027 — Ağ kopmasını izle; Bağlantı bekleniyor göstergesi ve geri gelince son konumdan yeniden açma ekle.
- [x] iP028 — 15 sn uzun tamponlamada Bağlantı yavaş — Tekrar dene uyarısı göster.
- [x] iP029 — Yetki/kilit, bulunamadı, zaman aşımı ve biçim hatalarını Türkçe sınıflandırıp teşhise yaz.
- [x] iP030 — VLC'nin bildirdiği akış/istatistik alanlarını gösteren Teknik bilgi sayfası ekle.
- [x] iP031 — Ses seçimini Türkçe dil adları ve işaretli etkin seçimle düzenle.
- [x] iP032 — Altyazı seçimini Türkçe dil adları, işaretli seçim ve Kapalı seçeneğiyle düzenle.
- [x] iP033 — Dizi başına son ses/altyazı seçimini cihazda hatırla ve profil tercihinden önce uygula.
- [x] iP034 — Canlı oynatıcıya açıldığı listedeki kanalları gösteren kanal paneli ekle.
- [x] iP035 — Canlı yayında CANLI'ya dön düğmesiyle akışı yeniden aç.
- [x] iP036 — Canlı başlığında sıradaki program bilgisini göster.
- [x] iP037 — Filmler için Otomatik/Yatay açılış yönü cihaz ayarı ekle.
- [x] iP038 — Varsayılan kapalı arka plan sesi ayarı ve arka planda video çizimini bırakıp sesi sürdürme akışı ekle.
- [x] iP039 — Oynatıcı açılışından ilk kareye kadar geçen süreyi Diagnostics'e yaz.
- [x] iP040 — Uzun süre etkileşimsiz dizi izlemeye Hâlâ izliyor musun? kontrolü ve sarma sırasında yüzde göstergesi ekle.

(Paketler burada maddelerini listeler.)
