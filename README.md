# NexRadar

**Arxa fonda işləyən yüzen radar & sürət göstəricisi** — Azerbaijan & Global Edition.

Navigasiya açmadan, telefon cibdə və ya kilidli olsa belə işləyən minimalist bir
baloncuk (floating HUD) üzərindən anlıq sürəti, qarşıdaki radarı, sürət həddini
və qalan məsafəni göstərir; hədd aşıldıqda səslə xəbərdarlıq edir.

> Android-first MVP. Bütün platforma-özel kod (`MethodChannel` arxasında)
> abstraktlaşdırılıb, ona görə iOS portu eyni Dart mühərrikini təkrar istifadə edə
> bilər.

---

## 1. Nə edir?

| Ssenari | Davranış |
| --- | --- |
| Sürüşürsən, qarşıda radar yoxdur | Baloncuk şəffaf/siyah — yalnız sürət (məs. `65`) görünür |
| Radara 1 km–200 m | Baloncuk **sarı/narıncı**: `Limit 80 · 350 m`, limit rəqəmi yanıb-sönür |
| Radara < 200 m və ya hədd aşılır | **Qırmızı flaşör** + həyəcan + vibrasiya |
| Radara 1 km qalmış | TTS: *"İrəlidə radar var, sürət həddi 80 kilometr saat, 1000 metr qaldı."* |
| Radara 500 m qalmış | TTS: eyni cümlə, yenilənmiş məsafə ilə; qulaqcıqda **bip** |
| Radara 200 m qalmış | TTS: *"Yavaşlayın, radara 200 metr qaldı!"* — həyəcan siqnalı |
| Radar ilk dəfə 200 m-dən yaxında görünürsə | **Heç bir anons yoxdur.** Keçilmiş qapılar səssiz qalır — "0 metr qaldı" xəbərdarlığı mənasızdır |
| Baloncukda `+`-a toxunmaq | Anlıq mövqe "Mobil YPX" kimi bildirilir, 2 saat canlı qalır |
| Telefon kilidlənib | Kilid ekranında sürət, limit və radara qalan məsafə görünür — HUD (erişilebilirlik pəncərəsi) və ya rəsmi bildiriş kartı |

Baloncuk sürüklənə bilər, **iki dəfə toxunmaqla** ölçüsü dəyişir (kiçik → normal →
böyük) və mövqeyi/ölçüsü yadda saxlanılır.

---

## 2. Memarlıq

```
lib/
├── core/
│   ├── constants/    app_constants.dart · camera_types.dart
│   ├── database/     db_helper.dart · camera_repository.dart
│   ├── location/     location_service.dart · heading_calculator.dart · speed_interpolator.dart
│   │                 route_corridor.dart (yol koridoru) · approach_ladder.dart (1km/500/200)
│   └── services/     overlay_service.dart · alert_service.dart · tts_service.dart
│                     crowdsourced_radar_service.dart · osm_sync_service.dart
│                     radar_engine.dart · settings_service.dart
├── models/           speed_camera.dart · vehicle_state.dart
├── ui/               theme/ (tokenlar + ThemeData) · widgets/ (dizayn sistemi)
├── views/            home_shell.dart
│   ├── onboarding/   onboarding_screen.dart   (ilk açılış + icazə axını)
│   ├── tabs/         drive_tab.dart · radars_tab.dart · settings_tab.dart
│   └── overlay/      floating_radar_bubble.dart
├── dev/              preview_main.dart        (brauzer üçün dizayn galereyası)
└── main.dart         (AppServices = servis lokatoru + bootstrap sırası)

android/app/src/main/kotlin/com/nexradar/app/
├── NexRadarApplication.kt   prosesdə yaşayan FlutterEngine-in sahibi
├── NexRadarChannels.kt      MethodChannel/EventChannel — aktivitiyə deyil, motora bağlıdır
├── MainActivity.kt          kilid ekranı bayraqları + paylaşılan motora qoşulma
├── RadarOverlayService.kt   ForegroundService + WindowManager overlay
├── NexRadarAccessibilityService.kt  kilid ekranı HUD-u (TYPE_ACCESSIBILITY_OVERLAY)
├── BubbleWindow.kt          pəncərə + mövqe/ölçü, iki host üçün ortaq
├── BubbleHost.kt            hansı host-un çəkdiyini seçir
├── SpeedBubbleView.kt       custom-drawn baloncuk, 60 FPS Choreographer
└── OverlayBus.kt            native ⇄ Dart körpüsü
```

### Məlumat axını (hər GPS fiksi, ≈1 Hz)

```
GPS ─▶ sürülən iz (RouteCorridor) ─▶ sabit yol istiqaməti (course)
        └─▶ SQLite keşi (5 km bbox + Haversine)
             └─▶ açısal filtr   |θ_heading − θ_camera| ≤ 45°
                  └─▶ yol filtri  radar koridordan ≤ 150 m uzaqda olmalıdır
                       └─▶ ən yaxın təhlükə
                            ├─▶ VehicleState  (status / limit / qalan m)
                            ├─▶ native baloncuk (payload)
                            ├─▶ TTS pilləkəni   1 km → 500 m → 200 m
                            └─▶ bip pilləkəni   500 m → 200 m / hədd aşımı
```

### Arxa fon: motoru kim saxlayır

Baloncuk ekranda qalıb donursa, səbəb adətən budur: **Dart isolate `FlutterActivity`
nün yaratdığı mühərrikin içində yaşayır və aktiviti bağlananda mühərriklə birlikdə ölür**.
Native foreground xidməti sağ qalır, ona görə baloncuk görünməyə davam edir — amma
GPS axını, anonslar və yaşıl xətt artıq yoxdur.

NexRadar bunu belə həll edir:

* mühərrik **`NexRadarApplication`**-a aiddir və proses boyu yaşayır;
* `MainActivity` onu `provideFlutterEngine` ilə **borc alır** və
  `shouldDestroyEngineWithHost()` **`false`** qaytarır (host-un verdiyi mühərrik üçün bu,
  Flutter embedding-in standart davranışıdır — yoxlanılıb);
* kanallar (`nexradar/overlay`, `nexradar/overlay_events`, `nexradar/update`)
  **mühərrikə** bağlanır, aktivitin ömrünə deyil;
* `RadarOverlayService` yarandığı anda mühərriki istəyir — proses öldükdən sonra Android
  xidməti `START_STICKY` ilə yenidən qaldıranda Dart tərəfi özü ayağa qalxır;
* Dart bootstrap-ı `overlayEnabled` yaddaşını görür və **UI olmadan** boru xəttini
  (`resumeInBackground`) işə salır;
* `RadarEngine` öz saatına malikdir ([`pumpInterval`], 10 Hz), çünki kada bağlı
  `Ticker` UI olmayanda heç işləmir — kadranın hədəfi donmasın deyə.

`onTaskRemoved` OEM tapşırıq qatillərinə qarşı foreground xidmətini yenidən təsdiqləyir.

### Yenidən başlatmadan sonra

Telefon restart olanda arxa fon tətbiqi üçün ən asan itki yeri budur: servis yalnız
tətbiqin öz activity-sindən başladılırsa, sürücü tətbiqi yenidən açana qədər radar
susur. `BootReceiver` `BOOT_COMPLETED` (və `MY_PACKAGE_REPLACED`) mesajını tutur və
**yalnız** sürücü baloncuğu açıq saxlayıbsa servisi yenidən qaldırır — bu da
`NexRadarApplication`-dan motoru istəyir, Dart `main()`-i işə düşür və boru xətti
UI-siz davam edir. Yəni səhər maşına əyləşəndə tətbiqi açmaq lazım deyil.

### Sürüş hesabatı

Panel "indi" cavabını verir; sürücünün səyahətdən sonra verdiyi sual isə başqadır:
*"yaxşı getdim?"* Ona görə engine sürüş boyu bir neçə rəqəm yığır — məsafə, orta və
maksimum sürət, limitdən yuxarı keçən **vaxt** (tunnel boşluqları çıxılmaqla),
anons sayı və keçilən radar sayı — və `drive_report.dart` bunları bir kartda
göstərir. Orta sürət eyni məsafə/vaxt arifmetikasıdır, yəni orta sürət kamerasının
hesabladığı rəqəm. Rəqəmlər tətbiq bağlıykən də artmağa davam edir, çünki onları
yazan boru xətti davam edir.

### 60 FPS "yağ kimi" göstərici

GPS çipi saniyədə bir dəfə veri verir. Ona görə hər iki tərəfdə eyni eksponensial
filtr tətbiq olunur (`current += (target − current)·(1 − e^(−dt/τ))`, `τ = 0.42 s`):

* **Dart** tərəfdə `SpeedInterpolator` — kadranı həm `HomeShell`-in `Ticker`-i (60 FPS),
  həm də mühərrikin öz nasosu (10 Hz) irəli aparır; addım həmişə **real keçən vaxtdan**
  hesablanır, ona görə filtr iki dəfə sürətlənmir və UI olmadıqda da donmur.
* **Native** tərəfdə `SpeedBubbleView` — `Choreographer` ilə öz render thread-ində hamarlayır.

Düstur frame-rate-dən asılı deyil (30/60/120 Hz eyni nəticə) və C¹ davamlıdır — yeni
fiks gələndə "sıçrayış" görünmür.

### Açısal hədəf filtri

`heading_calculator.dart` üç qaydanı tətbiq edir:

1. Radar **qabaqda** olmalıdır: `|θ_heading − θ_bearing_to_camera| ≤ 55°`.
2. Radar **bizim istiqamətimizi** ölçməlidir: `|θ_heading − θ_camera_direction| ≤ 45°`.
3. Əks şerit (180° fərq) və perpendikulyar küçələr (90° fərq) avtomatik düşür.

Tolerans tənzimləmələrdən 15°–90° aralığında dəyişdirilə bilər.

### Yol koridoru — "hansı yoldayam?"

Açısal filtr tək başına kifayət etmir: 3 km qabaqda, 200 m yan tərəfdə olan radar
cəmi ~4° kənara düşür və konusun içində qalır — halbuki sürücü o yola heç vaxt
çatmayacaq. `route_corridor.dart` bunu iki yolla düzəldir:

1. **Sabit yol istiqaməti.** İstiqamət GPS-in `heading` sahəsindən deyil, son ~60 m-də
   **həqiqətən sürülən xəttdən** götürülür. Yavaş sürətdə tərpənmir, döngələri özü izləyir,
   ona görə filtr yan küçələri "titrəyiş"lə içinə buraxmır.
2. **Koridor filtri.** Sürülən iz cari istiqamətdə 5 km qabağa uzadılır; radarlar bu xəttə
   olan məsafəyə görə ölçülür. 150 m-dən uzaq olan düşür.

Ehtiyatlı tərəfdədir: iz hələ qısadırsa (`< 60 m`) koridor **fikir bildirmir** və radar
saxlanılır. Real radarı itirmək, artıq birini saxlamaqdan qat-qat pisdir.

### Orta sürət bölmələri — bir nöqtə deyil, ortalama

Bölmə kamerası anda olan sürəti ölçmür: iki marker arasındakı **məsafəni vaxta bölür**.
Ona görə də sürücünün qarşısındakı rəqəm spidometrdə heç vaxt görünmür —
`average_speed_tracker.dart` məhz o rəqəmi hesablayır:

* **Odometr koridordan gəlir.** Düz xətt məsafəsi döngəli bölmədə az çıxır, az məsafə
  isə eyni vaxtda **daha aşağı** ortalama kimi görünür — sürücü cərimə yeyərkən
  "hər şey qaydasındadır" cavabı alardı. Odur ki, həqiqətən sürülən xətt ölçülür.
* **Saat marker *keçiləndə* başlayır.** Markera yaxınlaşma bölmənin içi deyil; onu da
  saymaq ortalamanı süni şəkildə aşağı salardı.
* Nəticə `Orta sürət bölməsi` kartında canlı göstərilir: ortalama, sürülən məsafə,
  keçən vaxt, həddən artıq olan fərq və ya qalan ehtiyat. limitdən yuxarı olduqda
  səsli xəbərdarlıq gedir (30 saniyəlik soyutma ilə — ortalama yavaş dəyişən rəqəmdir,
  təkrar danışmaq kömək deyil, səs-küydür).
* Bölmənin **çıxışı yoxdur**: OSM bir node verir, uydurma çıxış isə saxta "orta sürəti
  tut" rəqəmi yaradardı. Buna görə bölmə 1200 m-dən sonra avtomatik bağlanır.

### Diaqnostika və uçuş qeydi — "işləmirsə, niyə?"

Arxa fonun sükutla dayanması sürücünün verə biləcəyi yeganə cavabı mənasız edir:
"işləmir". Ona görə bütün diqqətəlayiq hadisələr **hər iki təbəqədən** (Kotlin servisi,
kilid ekranı hostu, Dart radar boru xətti) `filesDir/session.log` faylına yazılır və
boru xətti işlədiyi müddətdə 30 saniyədən bir **ürək döyüntüsü** qeyd olunur:

```
1791388051206|15:47:31|boot|process 9126 · Google sdk_gphone64_x86_64 · API 36
1791388054110|15:47:34|engine|started (background: true)
1791388054216|15:47:34|hb|fx 0 km/s · radar 0 · yol 0 m
1791388054269|15:47:34|service|foreground started
1791388054302|15:47:34|overlay|window attached
```

Növbəti açılışda bu fayl **tək sualı** cavablandırır: *"Mən çıxandan nə qədər sonra
həqiqətən öldü?"* — `summariseSession()` son ürək döyüntüsü ilə indiki vaxt arasındakı
fərqi oxuyur və `Diaqnostika` ekranı yuxarıda bir cümlə ilə göstərir.

`NexRadarDiagnostics` kanalı isə sistemdən **heç nəyi təxmin etmədən** soruşur: servis
işləyirmi, baloncuğu hansı host çəkir, kilid ekranı icazəsi varmı, bildirişlər açıqdırmı,
batareya optimallaşdırması və **doze standby bucket** nədir, son konum neçə saniyə
əvvəl gəldi, neçə radar kameraya düşdü, koridor neçə radarı başqa yolda sayıb atdı və
son anons hansı qapıda oldu. Ekrandakı hər maneə toxunula bilir və düzgün sistem
səhifəsini açır — çünki bunların hamısı sükutla baş verir və "tətbiq xarab olub"
kimi görünür.

---

## 3. UI / UX & dizayn sistemi

Arayüz Material 3 üzərində qurulmuş **tam dizayn sistemi** ilə yazılıb — heç bir ekran öz rəngini,
aralığını və ya şriftini özü seçmir.

```
lib/ui/
├── theme/
│   ├── app_theme.dart       rəng / spacing / radius / tipoqrafiya tokenları + ThemeData
│   └── status_palette.dart  status → rəng, CameraType → rəng, Fmt formatları
└── widgets/
    ├── surfaces.dart        NexCard · SectionHeader · StatusPill · StatBlock · NexIconBadge
    ├── controls.dart        Segmented · NexIconButton · NexActionTile · NexProgressRail
    ├── setting_tiles.dart   SettingGroup · SettingTile · SettingSwitch · SettingSlider
    ├── speed_gauge.dart     270° kadran (qradiyent yay, bezel tikleri, limit markeri, glow)
    ├── brand.dart           NexLogo · NexWordmark · RadarSweep
    └── app_header.dart      NexHeader
```

**Naviqasiya** — bir uzun siyahı yerinə üç nişanlı shell (`home_shell.dart`):
`Sürüş` (kadran + təhlükə paneli + əsas düymə + sürətli əməliyyatlar),
`Radarlar` (yaddaşdaki radarların filtrlənə bilən siyahısı + detal vərəqi),
`Ayarlar` (qruplaşdırılmış tənzimləmələr).

**İlk açılış** — `onboarding_screen.dart`: üç addımlı giriş (tanıtım → dil/vahid →
icazələr). İcazə ekranı hər `resume`-da sistem vəziyyətini yenidən oxuyur, çünki
"üstündə göstər" və "batareya" icazələri tətbiqdən çıxır.

**Kadran** — `speed_gauge.dart`:

* 270° yay + xarici bezel tikleri (dəqiq cihaz effekti);
* `SweepGradient` yay və uc nöqtədə parlaq "head" dairəsi;
* limit markeri; ölçək limitə uyğun sürüşür — 30 zonası da, magistral da rahatdır;
* xəbərdarlıqda nəbz edən xarici halqa və qırmızı accent;
* rəqəm `InterDisplay` + **tabular figures** — sayarkən tərpənmir.

**Tokenlər**: rənglər `NexColors`, aralıqlar `NexSpace`, radiuslar `NexRadius`,
şriftlər `NexText`. `Inter` şrifti **paketə daxil edilib** (`assets/fonts/`), çünki
tətbiq offline-first-dır — şrift şəbəkədən yüklənməməlidir.

### Dizaynı cihazsız görmək

```bash
# İnteraktiv galereya — bütün komponentlər brauzerdə
flutter run -d chrome -t lib/dev/preview_main.dart

# Golden PNG-lər: hər ekran 390×844 ölçüsündə test/goldens/ qovluğuna yazılır
flutter test --update-goldens test/design_test.dart
```

`test/design_test.dart` eyni zamanda **layout təhlükəsizliyi** testidir: hər
kompozisiya 390×844-də render olunur və hər hansı RenderFlex daşması testi düşürür.

---

## 4. Native baloncuk: nə üçün `flutter_overlay_window` deyil?

Layihə tapşırığında `flutter_overlay_window` nəzərdə tutulmuşdu. İstehsalatda
**native `WindowManager` overlay** (`RadarOverlayService` + `SpeedBubbleView`) seçildi:

| Meyar | `flutter_overlay_window` | Native overlay |
| --- | --- | --- |
| Kilid ekranı | ❌ ikinci engine pəncərəsi kilid ekranına buraxılmır | ✅ erişilebilirlik host-u ilə (aşağıya bax) |
| Ekran bağlıykən FPS | Dart isolate dayanır → kadr donur | ✅ native render thread |
| Yaddaş (RSS) | +≈60 MB (ikinci Flutter engine) | ≈0 |
| Build stabilliyi | 0.5.0 AGP 9 / Gradle 9.3 ilə riskli | ✅ heç bir xarici asılılıq |
| `flutter_overlay_window` API-si | dəstəklənir | eyni funksionallıq əl ilə |

`overlay_service.dart` Dart tərəfdəki müqavilədir — plugin dəyişsə də yuxarı qat
(`radar_engine.dart`) heç nə bilməz.

Baloncuk pəncərəsi **həmişə tam baloncuk ölçüsündədir**, ekran boyu deyil: tam ekran
şəffaf pəncərə telefonun bütün toxunuşlarını udar.

### Kilid ekranı: iki host, bir baloncuk

Android **kilid ekranı görünəndə adi overlay pəncərəsini həmişə gizlədir** və bunu
dəyişən flag yoxdur. `WindowManager` hər pəncərəyə kilid ekranı siyasəti tətbiq edir
(`WindowState.canBeHiddenByKeyguard`) və siyasət yalnız kilid ekranı host qatından
aşağıda oturan pəncərələrə şamil olunur:

| Pəncərə növü | Qat | Kilid ekranında görünür? |
| --- | --- | --- |
| `TYPE_APPLICATION_OVERLAY` | 11 | ❌ gizlədilir |
| `TYPE_NOTIFICATION_SHADE` (kilid ekranı host-u) | 17 | — |
| `TYPE_ACCESSIBILITY_OVERLAY` | 31 | ✅ |

`FLAG_SHOW_WHEN_LOCKED` burada kömək etmir: o, yalnız kilid ekranı artıq bir
`Activity` tərəfindən *occluded* edildikdə pəncərəni geri qaytarır — yəni heç vaxt
"kilid ekranının üstündə" demək deyil. Ona görə NexRadar **iki host** işlədir:

* `RadarOverlayService` → `TYPE_APPLICATION_OVERLAY`: ekran açıqkən, hər tətbiqin üstündə;
* `NexRadarAccessibilityService` → `TYPE_ACCESSIBILITY_OVERLAY`: **kilid ekranının üstündə**.

İkincisi Ayarlar → Erişilebilirlik-dən bir dəfə yandırılır (tətbiq ora özü yönləndirir)
və ekran məzmununu **oxumur** (`canRetrieveWindowContent="false"`). Aktiv olduqda
baloncugu yalnız o çəkir — foreground xidməti isə yenə də işləyir, çünki prosesi və GPS
axınını məhz o saxlamaqdadır (`BubbleHost` iki host arasında seçim edir).

Erişilebilirlik icazəsi verilməyibsə, kilid ekranında **rəsmi bildiriş kartı** eyni üç
rəqəmi göstərir — sürət · limit · radara qalan məsafə — və heç bir əlavə icazə
tələb etmir.

---

### Kilid ekranı paneli: media sessiyası (Spotify modeli)

Erişilebilirlik host-u baloncuğu kilid ekranına qoyur, amma **düymə yoxdur** və bəzi
ROM-larda kilid ekranı bildirişləri tamamilə gizlədilir. Telefonun həmişə göstərdiyi və
həmişə idarə etməyə icazə verdiyi səth **media pleyeridir** — Spotify-ın oturduğu yer.
NexRadar da orada oturur (`LockScreenControls`):

* `android.media.session.MediaSession` açılır (`setActive(true)`) və `MediaMetadata` +
  `PlaybackState` ilə canlı saxlanır;
* bildiriş `Notification.MediaStyle`-dır və sessiyanın tokenini daşıyır — SystemUI bu
  ikisini `EXTRA_MEDIA_SESSION` ilə birləşdirir və kartı kilid ekranına qaldırır;
* **artwork canlı sürət kadranıdır**: 256×256 bitmap yalnız görünən rəqəm dəyişəndə
  yenidən çəkilir (saniyədə ən çoxu bir dəfə), yəni kilid ekranında baloncuğun eynisini
  görürsən — sürət, limit nişanı və məsafə çipi ilə.

Düymələri SystemUI sessiyadan götürür (1-ci slot `PlaybackState`-dən, 2/3-cü slot
`ACTION_SKIP_TO_*`-dən):

| Slot | Düymə | Nə edir |
| --- | --- | --- |
| 1 | play / pauza | **Sükut rejimi** — bip və anonslar 5 dəqiqə susur |
| 2 | əvvəlki | **Səs** — səsli xəbərdarlığı aç/bağla |
| 3 | növbəti | **Radar bildir** — olduğun yerdə radar bildir |
| overflow | stop | **Dayandır** — baloncuğu və boru xəttini söndür |

Artıq bonus: media sessiyası qulaqlıq və avtomobilin media düymələrini də qəbul edir.

> **Sükut müddətlidir** (`WarningSilence`, 5 dəqiqə). Radar tətbiqini əbədi susdurmaq
> mümkün olsa, sürücü bir gün onu səssiz qoyub unudar və qalan yolu radarsız keçər.
> Müddət bitəndə xəbərdarlıqlar **özü** qayıdır, kilid ekranı kartı isə geri sayğacı
> göstərir (`Sükut · 4:12 sonra aktiv`), sükutda baloncuğun çipi `SÜKUT` olur və rəngi
> bozlaşır.

> **Sükutun sahibi Dart-dır.** Bip və anonslar Dart mühərrikindən çıxır, ona görə kilid
> ekranındaki düymə bir *istək* göndərir (`pauseWarnings` / `resumeWarnings` olayı),
> qərarı mühərrik verir və effektiv dəyəri növbəti state payload-u ilə geri göndərir.
> Düymənin öz ikonası isə dərhal dəyişir — sürücü Dart isolate-ni gözləmir.

> **Yeni icazə tələb olunmadı.** `mediaPlayback` foreground servis tipi və
> `FOREGROUND_SERVICE_MEDIA_PLAYBACK` **istifadə edilmir**: media kartı `MediaStyle` +
> sessiya tokenindən yaranır, servis tipindən deyil. Xidmət `specialUse` olaraq qalır və
> Play Console izahı dəyişmir. Android 16 (API 36) cihazlarda isə bildiriş
> `setShortCriticalText(...)` ilə status sətrində və kilid ekranında bir sətirlik sürəti
> də göstərir.

### "Kilid ekranında bağlanır" — artıq ölçülən bir sual

Servis `ACTION_SCREEN_OFF` / `SCREEN_ON` / `USER_PRESENT` yayımlarını dinləyir, hər keçidi
uçuş qeydinə yazır (`screen` sətri: `ekran bağlandı`, `kilid açıldı`) və kilid açılanda
hər iki host-u yenidən qiymətləndirir — bəzi OEM pəncərə menecerləri ekran bağlananda
overlay pəncərəsini tamamilə atır və baloncuk bir daha qayıtmır. Diaqnostika ekranındaki
**KİLİD EKRANI** kartı üç sualı cavablandırır: media paneli aktivdir? ekran açıqdır? kilid
bağlıdır? Yəni "kilid ekranında heç nə görmürəm" artıq təxmin deyil, üç baxıla bilən
dəyərdir.

---

## 5. İcazələr

| İcazə | Nə üçün |
| --- | --- |
| `ACCESS_FINE_LOCATION` | Sürət + radar yaxınlığı |
| `ACCESS_BACKGROUND_LOCATION` | Ekran bağlıykən izləmə |
| `SYSTEM_ALERT_WINDOW` | "Digər tətbiqlərin üzərində göstər" — baloncuk |
| `FOREGROUND_SERVICE` + `_LOCATION` + `_SPECIAL_USE` | Xidmətin öldürülməməsi |
| `POST_NOTIFICATIONS` | Daimi xidmət bildirişi (Android 13+) |
| `REQUEST_INSTALL_PACKAGES` | Tətbiq daxilində yeniləmə (APK-nı sistem quraşdırıcısına ötürmək) |
| `VIBRATE` | Hədd aşımında həyəcan |
| *erişilebilirlik xidməti* | Kilid ekranı HUD — Ayarlar → Erişilebilirlik-dən verilir, ekran oxunmur |

Kilid ekranı bildiriş kartında **sürət, limit, radara qalan məsafə və radar növü**
görünür (`VISIBILITY_PUBLIC`), üstündə iki əməliyyat: **"Radar bildir"** və **"Dayandır"**.

---

## 6. Topluluk (crowdsourcing) və məlumat bazası

* **Offline-first**: SQLite həmişə mənbədir. Tünel/qaranlıq rejimində bildiriş
  lokal yazılır və `pending_report` növbəsinə düşür, şəbəkə gələndə göndərilir.
* **2 saat qaydası**: mobil bölmə yerində durmur, ona görə hər topluluk bildirişi
  `expires_at` daşıyır və həm lokalde, həm remote-da təmizlənir.
* **OSM sinxronizasiyası**: Overpass API (`highway=speed_camera`,
  `enforcement=average_speed`, …) → tag parser (`maxspeed` = `80`, `50 mph`,
  `AZ:urban`; `direction` = `270` / `NW`) → SQLite upsert (idempotent).
* **Firebase Realtime Database**: `firebase_core`/`firebase_database` pubspec-də var.
  SDK konfiqurasiyası olmadan da işləməsi üçün əlavə olaraq **REST transport**
  yazılıb (`PUT /radars/<key>.json`) — `google-services.json` tələb etmir.

Tənzimləmələrdə ünvanı boş buraxsan, hər şey yalnız cihazda qalır (tam offline
rejim). URL-i belə də verə bilərsən:

```bash
flutter build apk --release \
  --dart-define=NEX_RADAR_FIREBASE_URL=https://your-app.firebaseio.com
```

---

## 7. Quraşdırma, derləmə və yeniləmə

```bash
flutter pub get
flutter analyze          # 0 issue
flutter test             # 75 test (63 məntiq + 6 layout + 6 golden)

# Release APK
flutter build apk --release --dart-define=NEX_RADAR_REPO=alihajiyev/nexradar
# → build/app/outputs/flutter-apk/app-release.apk

# Split ABI (kiçik fayllar, tövsiyə olunur)
flutter build apk --release --split-per-abi
```

`NEX_RADAR_REPO` — tətbiqin yeniləmə axtardığı GitHub `owner/repo` slug-ı. Verilməzsə
`alihajiyev/nexradar` işlədilir.

### Tətbiq daxilində yeniləmə

APK-nı telefona əl ilə köçürmək lazım deyil:

1. **Ayarlar → Yeniləmə → "Yoxla"** (açılışda avtomatik yoxlama da var, söndürülə bilər).
2. Tətbiq `https://api.github.com/repos/<slug>/releases/latest` sorğusunu göndərir;
   `compareVersions` quraşdırılmış `versionName`-i release teqi ilə müqayisə edir
   (`v1.2.3-beta+build` kimi formaları da başa düşür).
3. Yenisi varsa APK axın şəkildə `cacheDir/updates/`-ə endirilir (proqres göstərilir),
   sonra `FileProvider` (`content://…fileprovider/updates/…`) vasitəsilə sistem
   quraşdırıcısına ötürülür.
4. Yalnız ilk dəfə **"Naməlum mənbələrdən quraşdırma"** icazəsi soruşulur; tətbiq
   həmin ayar səhifəsinə özü yönləndirir.

### Sükutla yeniləmə (Shizuku)

Ən son Android versiyaları tətbiqin özünü dialoq olmadan yeniləməsinin qarşısını
alır: `REQUEST_INSTALL_PACKAGES` yalnız sistem qurşadırıcısını açır. Sürücüdə
**Shizuku** varsa, NexRadar ondan shell kimliyini borc alır və APK-nı
`pm install -S <ölçü>` içinə stdin ilə axıdaraq sükutla quraşdırır (fayl yolu ilə
yox — `pm` tətbiqin şəxsi keş qovluğunu oxuya bilmir).

Bu opsionaldır və **heç vaxt yeniləməni poza bilməz**: Shizuku yoxdursa, icazə
verilməyibsə və ya sükutla quraşdırma hər hansı səbəbdən alınmazsa, axın adi
qurşadırıcıya düşür. Qərar tək bir yerdə — `chooseInstallRoute()` — verilir və
testlərlə qorunur, çünki "optimist" cəhd sürücüyə gözlədiyi dialoq əvəzinə xəta
göstərərdi. Diaqnostika ekranı bu sətri də göstərir: aktiv / icazə gözləyir / yoxdur.

### Yeni sürüm yayımlamaq

`.github/workflows/release.yml` **main**-ə push-da `pubspec.yaml`-daki versiyanı oxuyur və
həmin versiya üçün GitHub Release yoxdursa APK-nı derləyib `v<sürüm>` teqi ilə yayımlayır.
`v*` teq push-u və əl ilə `workflow_dispatch` da işləyir.

```bash
# Yeganə addım: versiyanı qaldır və push et
#   pubspec.yaml: version: 1.5.0+6
git commit -am "chore: bump version"
git push
```

İş axını `flutter analyze` + `flutter test` keçmədən release yayımlamır.

### İmzalama — yeniləmənin şərti

Android eyni paketi **başqa açarla imzalanmış** APK ilə əvəz etmir
(`INSTALL_FAILED_UPDATE_INCOMPATIBLE`). CI hər run üçün təmiz maşındır: `~/.android/debug.keystore`
orasında yoxdur və hər build yeni açar yaradardı — yəni yeniləmə zənciri ilk gündən qırılardı.
Ona görə açar repo sirri kimi saxlanılır:

| Secret | Məzmun |
| --- | --- |
| `SIGNING_KEYSTORE_BASE64` | `base64 -w0 <keystore>` |
| `SIGNING_STORE_PASSWORD` | keystore parolu |
| `SIGNING_KEY_ALIAS` | açar alias-ı |
| `SIGNING_KEY_PASSWORD` | açar parolu |

CI bunları `android/key.properties`-ə yazır. Yerli maşında `android/key.properties`
yoxdursa build Flutter şablonunun debug açarına düşür (`android/app/build.gradle.kts`).

> Hazırkı release açarı **Android-in standart debug açarıdır**. Bu, artıq telefonda
> quraşdırılmış NexRadar ilə imza uyğunluğunu saxlayır — yəni yeniləmə ilk gündən işləyir,
> bir dəfəlik silib-yenidən quraşdırma tələb olunmur. Özəl açara keçmək istəsən, açarı
> dəyişmək **bir dəfəlik** silib-yenidən quraşdırma deməkdir.

---

## 8. Testlər

`test/widget_test.dart` + `test/update_service_test.dart` + `test/route_and_alerts_test.dart` +
`test/diagnostics_and_sections_test.dart` — **122 test**, hamısı pluginsiz işləyir:


* Haversine məsafə + bearing (4 kardinal istiqamət)
* `angularDifference` 0°/360° keçidi
* **Açısal filtr**: əks şerit, perpendikulyar küçə, bilinməyən istiqamət
* `SpeedInterpolator`: yaxınlaşma, **frame-rate müstəqilliyi**, clamp, deadband
* `VehicleState` pilləkəni: idle → approaching → warning, hədd aşımı toleransı, ETA
* OSM tag parser: `mph` çevrilməsi, `AZ:urban`, compass, zibil dəyərlərin rəddi
* `SpeedCamera` `toMap → fromMap` gediş-dönüş + `identityKey` dedup
* **`WarningSilence`**: geri sayım (`5:00` → `4:12`), pəncərənin dəqiq bitdiyi an,
  sıfıra sıxılma, saat geri qaçanda pəncərənin uzanmaması və `endsAtMillis` — kilid
  ekranı panelinin saydığı son tarix.
* **Sükutun yenidən başlatmaya davamı** (`SettingsService` + `SharedPreferences` mock):
  açıq pəncərə bərpa olunur, vaxtı keçmiş pəncərə **atılır** (yəni unudulmuş sükut bütün
  səfəri örtə bilməz), əl ilə bağlananda saxlanan son tarix də silinir.
* **Kilid ekranı düymələri** (`OverlayEvent`): `pauseWarnings` / `resumeWarnings` /
  `toggleVoice` / `addRadar` intent kimi tanınır, adi baloncuk toxunuşu isə onlarla
  qarışdırılmır.
* **`NativeDiagnostics` kilid ekranı**: media paneli, ekran/kilid vəziyyəti və sükut
  pəncərəsi xam xəritədən düzgün oxunur (kilid bağlı + panel yox = sürücünün görmədiyi
  yeganə hal).
* `PhraseBook`: AZ/TR/EN cümlələr və yuvarlaqlaşdırma (137 m → "140")
* **`UpdateService`**: release aşkarlanması (APK aktivinin seçilməsi, 404, şəbəkə
  xətası) və versiya arifmetikası (`v1.2.3-beta+build` normalizasiyası,
  `1.10.0 > 1.9.0` — sətir yox, ədəd müqayisəsi). GitHub cavabı `MockClient`,
  quraşdırılmış sürüm `nexradar/update` kanalının mock-u ilə verilir.
* **`ApproachLadder`**: qapının *keçilməsi* qaydası — ilk dəfə 30 m-də görünən radar
  üçün heç bir anons yoxdur (köhnə "0 metr" buqı), GPS boşluğu 900 m atlayanda yalnız
  ən təcili qapı səslənir, uzaqlaşma heç nə demir.
* **`RouteCorridor`**: sabit yol istiqaməti, "yolumda" filtri, izin qısaldılması və
  "fikir bildirmirəm" ehtiyatlılığı.
* **`HeadingCalculator`**: seqmentə perpendikulyar məsafə və `destination()` — koridorun
  həndəsəsi.
* **`AverageSpeedTracker`**: orta sürətin düzgün hesablanması (1000 m / 36 s = 100 km/s),
  sübut yoxdursa susma, 0.5 km/s toleransın cərimə sayılmaması, bölmənin 1200 m-də
  bağlanması, eyni kamera üçün saatın bir dəfə başlaması.
* **Uçuş qeydi**: sətir formatının parse edilməsi (pozan girişi atır, yıxılmır),
  `summariseSession()` — heç vaxt başlamamış, sağlam, gecikmiş və **42 dəqiqə əvvəl
  ölmüş** arxa fonun fərqləndirilməsi.
* **`NativeDiagnostics`**: maneələrin düzgün sırası (konum → üzərdə göstərmə → bildiriş →
  batareya → bucket), `RESTRICTED_BUCKET (45)` aşkarlanması və host adının sürücü
  dilinə çevrilməsi.
* **Sükutla yeniləmə marşrutu**: `chooseInstallRoute()` — Shizuku yoxdursa və ya
  icazə verilməyibsə sistem qurşadırıcısı, yalnız hər ikisi varsa sükut axını
  (optimist cəhdin sürücünü xəta ilə qoyub getməməsi üçün).
* **`DriveReport`**: məsafə/vaxt → orta sürət (60 km/s), təmiz sürüş cümləsi,
  qısa aşımın həyəcansız, uzun aşımın faizlə bildirilməsi, hərəkətsiz sürüşün
  sıfıra bölməməsi və saat geri qaçdıqda mənfi müddətin yaranmaması.

`test/design_test.dart` — 6 **layout təhlükəsizliyi** testi: hər kompozisiya 390×844-də
render olunur və hər hansı `RenderFlex` daşması testi düşürür. Səthlərdən biri
(`lockHud`) kilid ekranı HUD sətrinin üç vəziyyətini göstərir — sürücünün sistem
ayarlarında tapması lazım olan yeganə idarə elementi cihazsız yoxlanılır.

`test/golden_test.dart` — 6 golden müqayisəsi, `@Tags(['golden'])` ilə işarələnib.
Şrift rasterizatoru hosta bağlı olduğu üçün CI bunları `--exclude-tags golden` ilə keçir:

```bash
flutter test --update-goldens test/golden_test.dart   # golden-ları yenilə
flutter test --exclude-tags golden                    # CI-ın işlətdiyi dəst
```

> Qeyd: testlər iki real buqı tapdı və düzəldildi — filtrin hədəfdən bir az əvvəl
> donması və `parseDirection("nonsense")` → 0° (prefix uyğunluğu).

---

## 9. Saha testi — real Android 16 (API 36) cihazında

Bu sürüm yalnız unit testlərlə deyil, **real sistem imicində** yoxlanıldı
(`system-images;android-36;google_apis;x86_64`, Pixel 6 profili, release APK).
Lokal SDK `emulator` + AVD elle quruldu, APK `adb install` ilə yazıldı, icazələr
`pm grant` / `appops`, kilid ekranı hostu `settings put secure` ilə verildi.

**Təsdiqlənənlər (cihaz çıxışı):**

| Yoxlama | Nəticə |
|---|---|
| Release APK quraşdırılması | `Performing Streamed Install → Success` |
| Baloncuk pəncərəsi | `Window{... u0 com.nexradar.app} appop=SYSTEM_ALERT_WINDOW` |
| Foreground servis | `RadarOverlayService isForeground=true types=0x40000000`, bildiriş `vis=PUBLIC` |
| Konum servisi | `GeolocatorLocationService isForeground=true types=0x00000008` |
| Arxa fonda davamlılıq | `hb` sətirləri **hər 30 saniyə** gəldi, heç bir UI açıq olmadan |
| Uçuş qeydi | `boot → engine → started(background: true) → service → overlay → hb` tam ardıcıllıq |
| DB oxunması | `sqlite3` ilə bazaya 3 radar yazıldı, tətbiq həmin faylı istifadə etdi |

Nümunə — cihazın özünün yazdığı jurnal:

```
1791388051206|15:47:31|boot|process 9126 · Google sdk_gphone64_x86_64 · API 36
1791388051753|15:47:31|engine|dart entrypoint started
1791388054110|15:47:34|engine|started (background: true)
1791388054269|15:47:34|service|foreground started
1791388054302|15:47:34|overlay|window attached
1791388084315|15:48:04|hb|fx 0 km/s · radar 0 · yol 0 m
1791388168324|15:49:28|hb|fx 0 km/s · radar 0 · yol 0 m
```

**Yoxlanıla bilməyənlər — dürüst qeyd:** imicin GNSS HAL-ı `adb emu geo fix`
əmrini qəbul etsə də sistemə heç bir fix ötürmədi (`gps provider: locations = 0`),
ona görə **GPS-dən asılı olan** hissə (1 km → 500 m → 200 m merdiveni, koridor
filtri, orta sürət bölməsi) cihazda işə salına bilmədi; bunlar unit testlərlə
(qapı keçmə qaydası, koridor həndəsəsi, ortalama hesablanması) qorunur.
`enabled_accessibility_services` yazmaq da imicdə qüvvədə qalmadı, yəni
kilid ekranı hostu cihazda təsdiqlənmədi.

### v1.5.0 — kilid ekranı media paneli (real Android 16, API 36)

Media paneli cihazda yoxlanıldı; aşağıdakılar sistemin **öz dömpündən** götürülüb
(`dumpsys media_session`, `dumpsys notification --noredact`):

```
Sessions Stack - have 1 sessions:
  NexRadarLockScreen com.nexradar.app/NexRadarLockScreen/4
    active=true
    launchIntent=PendingIntent{... com.nexradar.app startActivity ...}
    state=PlaybackState {state=PLAYING(3), speed=1.0, actions=560,
      custom actions=[Action:mName='Radarı dayandır, ...]}
    metadata: size=4, description=NexRadar aktivdir, Kilid ekranı paneli hazırdır, NexRadar
```

* `actions=560` = `PLAY_PAUSE | SKIP_TO_PREVIOUS | SKIP_TO_NEXT` — kilid ekranının üç
  düyməsi (sükut/səs/bildir) sessiyada **var**, dördüncü ("Radarı dayandır") overflow
  slotundadır.
* Bildiriş: `category=transport`, `actions=3`, `vis=PUBLIC`,
  `android.template=String (android.app.Notification$MediaStyle)` və
  `android.mediaSession=Token (android.media.session.MediaSession$Token@…)` — yəni
  SystemUI-nin kartı media pleyerinə qaldırması üçün lazım olan iki şey (media template
  + sessiya tokeni) yerindədir; `android.largeIcon` isə kadran bitmapidir.
* Sükut rejimi Dart-dan native-ə state payload-u ilə ötürüldü və panel geri saydı:
  `android.title=🔇 0 km/s`, `android.text=Sükut · 2:29 sonra aktiv · limit məlum deyil`,
  `android.shortCriticalText=SÜKUT` (Android 16), sessiya isə `PAUSED(2)` oldu — yəni
  kilid ekranındaki düymə "play"a çevrilir və sürücü sükutu bir toxunuşla aça bilir.

**Yoxlanıla bilməyən:** kilid ekranının *rəsmi görüntüsü* — imicdə kilid ekranı heç
qurulmamışdır (`isKeyguardShowing=false`), ona görə panelin keyguard-da necə çəkildiyi
burada təsdiqlənmədi. Yuxarıdaki iki siyahı isə onun bütün **girdilərinin** (MediaSession
+ MediaStyle + token + metadata + short critical text) sistemdə hazır olduğunu göstərir.

---

## 10. Yol xəritəsi

* Android Auto / Wear OS bildirişi
* Orta sürət bölmələri üçün OSM `relation` dəstəyi (real giriş-çıxış cütləri)
* Xəritədə radar heatmap + "yoldaş rejimi"
* iOS portu (`CoreLocation` + `UIWindow` overlay; Dart tərəfi hazırdır)

Bitmiş addımlar: kilid ekranı HUD (erişilebilirlik host-u + publik bildiriş kartı),
sabit 5 km radar ufqu, tətbiq daxilində yeniləmə və GitHub Releases boru xətti,
kilid ekranı media paneli (pauza/səs/bildir düymələri, canlı kadran artwork-ü) və
müddətli sükut rejimi,
`Inter`/`InterDisplay` dizayn sistemi.
