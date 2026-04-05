# Birdz iOS App – Návod na inštaláciu (NOVÝ)

## Čo potrebuješ
- MacBook Air M2 (máš ✅)
- Xcode nainštalovaný (máš ✅)
- Apple ID (máš ✅)

---

## ⚠️ DÔLEŽITÉ – Ak si predtým už pridával staré Swift súbory

V Xcode **zmaž** tieto staré súbory (ak existujú):
- `BirdzNotificationPlugin.swift`
- `AppDelegate+Birdz.swift`
- `BirdzMonitorInjectedScript.swift`

Klikni na ne pravým → **Delete** → **Move to Trash**

Tiež v `AppDelegate.swift` **odstráň** riadok `setupBirdzMonitoring()` ak si ho tam predtým pridal.

---

## Krok 1: Stiahni najnovší kód

V Terminale v priečinku projektu:
```bash
git pull
npm install
npx cap sync
npx cap open ios
```

## Krok 2: Pridaj JEDEN Swift súbor do Xcode

1. V Xcode v ľavom paneli nájdi priečinok **App** (pod "App" → "App")
2. Klikni pravým tlačidlom na **App** → **Add Files to "App"...**
3. Nájdi v projekte priečinok `ios-plugin/` a pridaj **IBA JEDEN** súbor:
   - ✅ `BirdzViewController.swift`
4. Zaškrtni **"Copy items if needed"** a **"Add to target: App"**

**NEPRIDÁVAJ** žiadne iné Swift súbory z ios-plugin!

## Krok 3: Prepoj ViewController (KĽÚČOVÝ KROK!)

Toto je najdôležitejší krok – hovorí Capacitoru, aby použil náš vlastný ViewController namiesto štandardného.

1. V Xcode otvor súbor `ios/App/App/AppDelegate.swift`
2. Nájdi riadok:
```swift
let vc = CAPBridgeViewController()
```
3. **Zmeň ho na:**
```swift
let vc = BirdzViewController()
```

Ak tam nie je presne `CAPBridgeViewController()`, hľadaj miesto, kde sa vytvára hlavný ViewController a nahraď ho za `BirdzViewController()`.

**Alternatíva:** Ak v `AppDelegate.swift` nevidíš žiadny `CAPBridgeViewController`, otvor namiesto toho súbor `ios/App/App/MainViewController.swift` (ak existuje) a zmeň:
```swift
// Z:
class MainViewController: CAPBridgeViewController {
// Na:  
class MainViewController: BirdzViewController {
```

Ak ani `MainViewController.swift` neexistuje, tak:
1. V Xcode klikni **File → New → File → Swift File**
2. Pomenuj ho `MainViewController.swift`
3. Vlož tento obsah:
```swift
import UIKit
import Capacitor

class MainViewController: BirdzViewController {
}
```

## Krok 4: Nastav ikonu appky
1. V Xcode klikni na **Assets.xcassets** → **AppIcon**
2. Pretiahni logo Birdz na všetky sloty

## Krok 5: Signing & Capabilities
1. Klikni na **App** (modrá ikona hore) → **Signing & Capabilities**
2. Zaškrtni **Automatically manage signing**, vyber svoj Team
3. Klikni **+ Capability** → pridaj **Push Notifications**
4. Klikni **+ Capability** → pridaj **Background Modes** → zaškrtni **Background fetch**

## Krok 6: Spusti na iPhone
1. Pripoj iPhone cez kábel
2. Vyber svoj iPhone v dropdown hore
3. Stlač `Cmd + R`

### Ak "Untrusted Developer":
iPhone → **Nastavenia → Všeobecné → VPN a správa zariadení** → Dôverovať

---

## Hotovo! 🎉

### Čo funguje:
- ✅ **Safe area** – obsah pod stavovým riadkom (natívne cez contentInsetAdjustmentBehavior)
- ✅ **Pinch-to-zoom** – ako v Safari
- ✅ **Swipe späť/vpred** – natívne gesto
- ✅ **Pull-to-refresh** – potiahni nadol (červený spinner)
- ✅ **Dlhý stisk** – uloženie obrázkov, náhľad linkov
- ✅ **Badge** – počet notifikácií na ikone
- ✅ **iOS notifikácie** – typ (TS, reakcia, komentár) + náhľad textu
- ✅ **5s polling** – automatická kontrola nových notifikácií

## Riešenie problémov

### Nič sa nezmenilo oproti predtým
- Skontroluj, že v kóde naozaj používaš `BirdzViewController()` namiesto `CAPBridgeViewController()`
- Bez tohto kroku sa náš kód **vôbec nespustí**!

### Notifikácie nefungujú
- Musíš byť prihlásený na birdz.sk
- Nastavenia iPhone → Birdz → Upozornenia → všetko zapnuté
