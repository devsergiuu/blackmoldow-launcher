# Black Moldow launcher (iOS)

Launcher nou pentru același client ReSA: se înlocuiește doar `App.framework/App`, iar `ReSALauncher`, `alyn_resa.framework` și `Flutter.framework` rămân cele originale din `base.ipa`.

Layoutul e cel din `com.moldow.pr/app/src/main/res/layout/activity_main.xml`, cu drawable-urile reale rasterizate în `assets/android/`.

## Build

Rulează manual workflow-ul **Build Black Moldow iOS launcher** din tab-ul Actions. Pe un runner macOS se compilează Flutter 3.47.2 (engine `a804b261`), se înlocuiește App.framework în `base.ipa` și se încarcă artifactul `blackmoldow-launcher.ipa`.

Butonul JOACA trimite `startGame` pe `ro.alynsampmobile.launcher/bridge` cu `host=51.75.44.14`, `port=8889`. Nickname-ul se citește din `client_settings.plist`.
