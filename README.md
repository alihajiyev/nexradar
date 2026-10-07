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
| Radara 500–200 m | Baloncuk **sarı/narıncı**: `Limit 80 · 350 m`, limit rəqəmi yanıb-sönür |
| Radara < 200 m və ya hədd aşılır | **Qırmızı flaşör** + bip + vibrasiya |
| 400 m qalmış | TTS: *"İrəlidə radar var, sürət həddi 80 kilometr saat, 400 metr qaldı."* |
| 150 m qalmış | TTS: *"Yavaşlayın, radara 150 metr qaldı!"* |
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
├── MainActivity.kt          kilid ekranı bayraqları + MethodChannel/EventChannel
├── RadarOverlayService.kt   ForegroundService + WindowManager overlay
├── SpeedBubbleView.kt       custom-drawn baloncuk, 60 FPS Choreographer
└── OverlayBus.kt            native ⇄ Dart körpüsü
```

### Məlumat axını (hər GPS fiksi, ≈1 Hz)

```
GPS ─▶ heading ─▶ SQLite keşi (2 km bbox + Haversine)
                    └─▶ açısal filtr  |θ_heading − θ_camera| ≤ 45°
                          └─▶ ən yaxın təhlükə
                               ├─▶ VehicleState  (status / limit / qalan m)
                               ├─▶ native baloncuk (payload)
                               ├─▶ TTS pilləkəni   400 m → 150 m
                               └─▶ bip pilləkəni   500 m → 200 m / hədd aşımı
```

### 60 FPS "yağ kimi" göstərici

GPS çipi saniyədə bir dəfə veri verir. Ona görə hər iki tərəfdə eyni eksponensial
filtr tətbiq olunur (`current += (target − current)·(1 − e^(−dt/τ))`, `τ = 0.42 s`):

* **Dart** tərəfdə `SpeedInterpolator` — tətbiq içindəki kadranı `Ticker` (60 FPS) idarə edir.
* **Native** tərəfdə `SpeedBubbleView` — `Choreographer` ilə öz render thread-ində hamarlayır.

Düstur frame-rate-dən asılı deyil (30/60/120 Hz eyni nəticə) və C¹ davamlıdır — yeni
fiks gələndə "sıçrayış" görünmür.

### Açısal hədəf filtri

`heading_calculator.dart` üç qaydanı tətbiq edir:

1. Radar **qabaqda** olmalıdır: `|θ_heading − θ_bearing_to_camera| ≤ 55°`.
2. Radar **bizim istiqamətimizi** ölçməlidir: `|θ_heading − θ_camera_direction| ≤ 45°`.
3. Əks şerit (180° fərq) və perpendikulyar küçələr (90° fərq) avtomatik düşür.

Tolerans tənzimləmələrdən 15°–90° aralığında dəyişdirilə bilər.

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
flutter test             # 56 test (44 məntiq + 6 layout + 6 golden)

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

### Yeni sürüm yayımlamaq

`.github/workflows/release.yml` **main**-ə push-da `pubspec.yaml`-daki versiyanı oxuyur və
həmin versiya üçün GitHub Release yoxdursa APK-nı derləyib `v<sürüm>` teqi ilə yayımlayır.
`v*` teq push-u və əl ilə `workflow_dispatch` da işləyir.

```bash
# Yeganə addım: versiyanı qaldır və push et
#   pubspec.yaml: version: 1.2.0+4
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

`test/widget_test.dart` + `test/update_service_test.dart` — 44 test, hamısı pluginsiz işləyir:


* Haversine məsafə + bearing (4 kardinal istiqamət)
* `angularDifference` 0°/360° keçidi
* **Açısal filtr**: əks şerit, perpendikulyar küçə, bilinməyən istiqamət
* `SpeedInterpolator`: yaxınlaşma, **frame-rate müstəqilliyi**, clamp, deadband
* `VehicleState` pilləkəni: idle → approaching → warning, hədd aşımı toleransı, ETA
* OSM tag parser: `mph` çevrilməsi, `AZ:urban`, compass, zibil dəyərlərin rəddi
* `SpeedCamera` `toMap → fromMap` gediş-dönüş + `identityKey` dedup
* `PhraseBook`: AZ/TR/EN cümlələr və yuvarlaqlaşdırma (137 m → "140")
* **`UpdateService`**: release aşkarlanması (APK aktivinin seçilməsi, 404, şəbəkə
  xətası) və versiya arifmetikası (`v1.2.3-beta+build` normalizasiyası,
  `1.10.0 > 1.9.0` — sətir yox, ədəd müqayisəsi). GitHub cavabı `MockClient`,
  quraşdırılmış sürüm `nexradar/update` kanalının mock-u ilə verilir.

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

## 9. Yol xəritəsi

* Android Auto / Wear OS bildirişi
* Orta sürət (average speed) zonaları üçün giriş-çıxış cütləri
* Xəritədə radar heatmap + "yoldaş rejimi"
* iOS portu (`CoreLocation` + `UIWindow` overlay; Dart tərəfi hazırdır)

Bitmiş addımlar: kilid ekranı HUD (erişilebilirlik host-u + publik bildiriş kartı),
sabit 5 km radar ufqu, tətbiq daxilində yeniləmə və GitHub Releases boru xətti,
`Inter`/`InterDisplay` dizayn sistemi.
