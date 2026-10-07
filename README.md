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
| Telefon kilidlənib | Ekranı yandırdıqda baloncuk **şifrə soruşmadan** kilid ekranında görünür |

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
| Kilid ekranı (`FLAG_SHOW_WHEN_LOCKED`) | ❌ ikinci engine pəncərəsi kilid ekranına buraxılmır | ✅ tam nəzarət |
| Ekran bağlıykən FPS | Dart isolate dayanır → kadr donur | ✅ native render thread |
| Yaddaş (RSS) | +≈60 MB (ikinci Flutter engine) | ≈0 |
| Build stabilliyi | 0.5.0 AGP 9 / Gradle 9.3 ilə riskli | ✅ heç bir xarici asılılıq |
| `flutter_overlay_window` API-si | dəstəklənir | eyni funksionallıq əl ilə |

`overlay_service.dart` Dart tərəfdəki müqavilədir — plugin dəyişsə də yuxarı qat
(`radar_engine.dart`) heç nə bilməz.

---

## 5. İcazələr

| İcazə | Nə üçün |
| --- | --- |
| `ACCESS_FINE_LOCATION` | Sürət + radar yaxınlığı |
| `ACCESS_BACKGROUND_LOCATION` | Ekran bağlıykən izləmə |
| `SYSTEM_ALERT_WINDOW` | "Digər tətbiqlərin üzərində göstər" — baloncuk |
| `FOREGROUND_SERVICE` + `_LOCATION` + `_SPECIAL_USE` | Xidmətin öldürülməməsi |
| `POST_NOTIFICATIONS` | Daimi xidmət bildirişi (Android 13+) |
| `VIBRATE` | Hədd aşımında həyəcan |

Baloncuk bildirişində iki əməliyyat var: **"Radar bildir"** və **"Dayandır"**.

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

## 7. Quraşdırma və derləmə

```bash
flutter pub get
flutter analyze          # 0 issue
flutter test             # 39 test (34 məntiq + 5 dizayn/layout)

# Release APK
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk

# Split ABI (kiçik fayllar, tövsiyə olunur)
flutter build apk --release --split-per-abi
```

Kilid ekranında sınamaq üçün:

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell am start -n com.nexradar.app/.MainActivity
```

### Release imzalama (növbəti addım)

Hazırda `android/app/build.gradle.kts` debug açarı ilə imzalayır (Flutter şablonu),
yəni APK dərhal quraşdırılır. Play Store üçün:

```kotlin
release {
    signingConfig = signingConfigs.getByName("release")
}
```

---

## 8. Testlər

`test/widget_test.dart` — 34 test, hamısı pluginsiz işləyir:

* Haversine məsafə + bearing (4 kardinal istiqamət)
* `angularDifference` 0°/360° keçidi
* **Açısal filtr**: əks şerit, perpendikulyar küçə, bilinməyən istiqamət
* `SpeedInterpolator`: yaxınlaşma, **frame-rate müstəqilliyi**, clamp, deadband
* `VehicleState` pilləkəni: idle → approaching → warning, hədd aşımı toleransı, ETA
* OSM tag parser: `mph` çevrilməsi, `AZ:urban`, compass, zibil dəyərlərin rəddi
* `SpeedCamera` `toMap → fromMap` gediş-dönüş + `identityKey` dedup
* `PhraseBook`: AZ/TR/EN cümlələr və yuvarlaqlaşdırma (137 m → "140")

> Qeyd: testlər iki real buqı tapdı və düzəldildi — filtrin hədəfdən bir az əvvəl
> donması və `parseDirection("nonsense")` → 0° (prefix uyğunluğu).

---

## 9. Yol xəritəsi

* Android Auto / Wear OS bildirişi
* Orta sürət (average speed) zonaları üçün giriş-çıxış cütləri
* Xəritədə radar heatmap + "yoldaş rejimi"
* iOS portu (`CoreLocation` + `UIWindow` overlay; Dart tərəfi hazırdır)
