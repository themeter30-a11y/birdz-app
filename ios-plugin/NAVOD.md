# Birdz iOS App - Návod na inštaláciu

## Čo potrebuješ
- MacBook Air M2 (máš ✅)
- Xcode (zadarmo z App Store)
- Apple ID (máš ✅)

## Krok 1: Nainštaluj Xcode
Otvor App Store na Macbooku a stiahni **Xcode** (je zadarmo, ale má ~12 GB).

## Krok 2: Nainštaluj Node.js
Otvor **Terminal** (Finder → Aplikácie → Utility → Terminal) a skopíruj:
```bash
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash
source ~/.zshrc
nvm install 20
```

## Krok 3: Exportuj projekt z Lovable
1. V Lovable klikni na **"Export to GitHub"** (alebo stiahni ZIP)
2. Na Macbooku otvor Terminal a spusti:
```bash
cd ~/Desktop
git clone TVOJ_GITHUB_LINK
cd NAZOV_PROJEKTU
```
(Ak si stiahol ZIP, rozbaľ ho na Desktop a otvor Terminal v tom priečinku)

## Krok 4: Nainštaluj závislosti a pridaj iOS
```bash
npm install
npx cap add ios
npx cap sync
```

## Krok 5: Pridaj Swift súbory do Xcode
```bash
npx cap open ios
```
Toto otvorí Xcode. Potom:

1. V Xcode v ľavom paneli nájdi priečinok **App** (pod "App" → "App")
2. Klikni pravým tlačidlom na priečinok **App** → **Add Files to "App"...**
3. Nájdi v projekte priečinok `ios-plugin/` a pridaj oba súbory:
   - `BirdzNotificationPlugin.swift`
   - `AppDelegate+Birdz.swift`
4. Uisti sa, že je zaškrtnuté **"Copy items if needed"**
5. **Nepridávaj** `BirdzMonitorInjectedScript.swift` — už sa nepoužíva. Ak si ho do Xcode pridal skôr, zmaž ho z projektu aj z targetu App.

## Krok 6: Uprav AppDelegate.swift
V Xcode otvor súbor `App/AppDelegate.swift` a nájdi funkciu:
```swift
func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
```

Hneď za otváraciu `{` pridaj tento riadok:
```swift
        setupBirdzMonitoring()
```

Takže to bude vyzerať takto:
```swift
func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    setupBirdzMonitoring()
    // ... ostatný kód ...
    return true
}
```

## Krok 7: Nastav podpisovanie (Signing)
1. V Xcode klikni na **App** v ľavom paneli (hore, modrá ikona)
2. Prejdi na záložku **Signing & Capabilities**
3. Zaškrtni **Automatically manage signing**
4. V **Team** vyber svoj Apple ID
5. Ak nemáš Team, klikni **Add Account** a prihlás sa svojím Apple ID

## Krok 8: Pridaj Push Notifications capability
1. V rovnakej záložke **Signing & Capabilities**
2. Klikni **+ Capability**
3. Nájdi a pridaj **Push Notifications**
4. Nájdi a pridaj **Background Modes** → zaškrtni **Background fetch**

## Krok 9: Spusti na iPhone
1. Pripoj iPhone cez kábel k Macbooku
2. Na iPhone potvŕď **"Dôverovať tomuto počítaču"**
3. V Xcode hore vyber svoj iPhone z dropdown menu (vedľa "App")
4. Klikni ▶️ (Play tlačidlo) alebo stlač `Cmd + R`
5. Prvýkrát to môže trvať 2-3 minúty

### Ak sa objaví chyba "Untrusted Developer":
Na iPhone choď do **Nastavenia → Všeobecné → VPN a správa zariadení** → nájdi svoj Apple ID → klikni **Dôverovať**

## Hotovo! 🎉

Appka by sa mala otvoriť na tvojom iPhone s birdz.sk na fullscreen.
- Každých 30 sekúnd kontroluje nové notifikácie
- Keď príde nová notifikácia, pošle ti iOS upozornenie
- Badge na ikone appky ukazuje počet neprečítaných

## Riešenie problémov

### Notifikácie nefungujú
- Uisti sa, že si na birdz.sk prihlásený
- Skontroluj Nastavenia → Birdz → Upozornenia → všetko zapnuté
- Appka musí bežať aspoň na pozadí

### Badge selektory sa zmenili
Ak birdz.sk zmení dizajn stránky, bude treba upraviť JavaScript v súbore `BirdzNotificationPlugin.swift`. Kontaktuj ma a pomôžem ti to opraviť.

### Appka sa neotvára
- Skontroluj, že máš internet
- Reštartuj appku
