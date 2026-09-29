import AppKit
import WebKit
import PasswordKit

/// #17 Addresses, cards and one-time codes in forms; passkeys.
extension FeatureSelfTest {

    private final class Confirmer: PasswordAuthenticator {
        var answer = true
        var asked: [String] = []
        func authenticate(reason: String) async -> Bool {
            asked.append(reason)
            return answer
        }
    }

    func autofillForms() async {
        let browser = first
        let service = app.passwords(for: browser.profile)
        let confirmer = Confirmer()
        let previous = service.authenticator
        service.authenticator = confirmer
        defer { service.authenticator = previous }
        guard let vault = service.autofill else { check("autofill: (setup) a vault", false); return }
        let home = AutofillAddress(label: "Home", fullName: "Ada Lovelace", street: "12 St James's Square\nFlat 3", city: "London",
                                   postalCode: "SW1Y 4JH", country: "GB", email: "ada@example.com")
        let visa = AutofillCard(nameOnCard: "A Lovelace", number: "4242424242424242", expiryMonth: 7, expiryYear: 2029)
        try? await vault.save(home)
        try? await vault.save(visa)
        let fill = browser.autofill

        // One confirmation fills name, address and card.
        await open("/checkout", in: browser)
        _ = await js("document.getElementById('given').focus()", in: browser)
        check("autofill: a checkout field offers name, address and card at once", await waitFor { fill.offered.first == "Home · Visa •••• 4242" }, fill.offered)
        check("autofill: …then each address", fill.offered.contains(home.summary) && fill.offered.last == "AutoFill Settings…")
        snapshot(browser.window, "autofill-offer")
        _ = await js("window.heardInputs = 0; document.addEventListener('input', () => window.heardInputs++, true)", in: browser)
        fill.suggestions.rows.first?.choose()
        check("autofill: choosing it asks, once, that it is you", await waitFor { confirmer.asked == ["fill your card details"] }, confirmer.asked)
        func values(_ ids: [String]) async -> [String] {
            (await js("return \(ids).map(id => document.getElementById(id).value)", in: browser) as? [String]) ?? []
        }
        let ids = ["given", "family", "line1", "line2", "city", "country", "zip", "email", "ccname", "ccnumber", "ccmonth", "ccyear", "csc"]
        check("autofill: …and the whole form is filled", await waitFor {
            await values(ids) == ["Ada", "Lovelace", "12 St James's Square", "Flat 3", "London", "GB", "SW1Y 4JH", "ada@example.com",
                                   "A Lovelace", "4242424242424242", "07", "2029", ""]
        }, await values(ids))
        let heard = (await js("return window.heardInputs", in: browser) as? NSNumber)?.intValue ?? 0
        check("autofill: the page's own code hears each field change, as if typed", heard >= 12, heard)
        check("autofill: the security code is left to you", (await values(["csc"])) == [""])

        // Said no to: nothing is filled.
        await open("/checkout", in: browser)
        confirmer.answer = false
        _ = await js("document.getElementById('ccnumber').focus()", in: browser)
        _ = await waitFor { fill.offered.contains(visa.masked) }
        check("autofill: a card field offers the cards", fill.offered.first == "Home · Visa •••• 4242" && fill.offered.contains(visa.masked), fill.offered)
        fill.suggestions.rows.first { $0.item.title == visa.masked }?.choose()
        await pause(0.5)
        check("autofill: not confirmed, no card is filled", (await values(["ccnumber"])) == [""])
        confirmer.answer = true

        // A shop that labels nothing; a card typed by hand is offered to be kept.
        await open("/checkout-legacy", in: browser)
        _ = await js("document.getElementById('fname').focus()", in: browser)
        check("autofill: a form without labels for machines is still understood", await waitFor { fill.offered.first?.hasPrefix("Home") == true }, fill.offered)
        _ = await js("""
            const set = (id, v) => { document.getElementById(id).value = v; };
            set('fname', 'Grace'); set('lname', 'Hopper'); set('address1', '1 Navy Way'); set('city', 'Arlington'); set('zip', '22201');
            set('ccnum', '5555 5555 5555 4444'); set('ccexp', '12/31'); set('cvv', '123');
            document.getElementById('buy').click();
            """, in: browser)
        check("autofill: a new card and address typed in are offered to be saved", await waitFor { fill.pendingSave?.card?.number == "5555555555554444" && fill.pendingSave?.address?.city == "Arlington" },
              fill.pendingSave as Any)
        check("autofill: …asked in a popover", await waitFor { fill.savePopover?.isShown == true })
        snapshot(browser.window, "autofill-save")
        fill.answerSave(true)
        check("autofill: Save keeps them, without the security code", await waitFor {
            let saved = (try? await vault.contents()) ?? .init()
            return saved.cards.contains { $0.number == "5555555555554444" && $0.expiryYear == 2031 } && saved.addresses.contains { $0.fullName == "Grace Hopper" }
        })
        let raw = (try? await vault.contents()).map { String(describing: $0) } ?? ""
        check("autofill: …which is nowhere in what is kept", !raw.contains("\"123\""))

        // Private windows keep nothing typed.
        app.newPrivateWindow(nil)
        if let privately = app.browserControllers.last(where: \.isPrivate) {
            check("autofill: a private window offers to keep nothing", privately.autofill.allowsSaving == false)
            privately.window?.performClose(nil)
        }

        // One-time codes: a native field macOS fills from Messages and Mail.
        await open("/otp", in: browser)
        _ = await js("document.getElementById('code').focus()", in: browser)
        check("autofill: a one-time code field opens a code field of the Mac's own", await waitFor { fill.codePopover?.isShown == true && fill.codeField?.contentType == .oneTimeCode })
        fill.fillCode("493817")
        check("autofill: …and the code goes into the page", await waitFor { (await values(["code"])) == ["493817"] })

        // Passkeys: the page's request reaches the browser, which asks macOS when it may.
        await open("/webauthn", in: browser)
        let before = fill.passkeyRequests
        _ = await js("document.getElementById('passkey').click()", in: browser)
        let seen = await waitFor { fill.passkeyRequests > before }
        let credentials = await js("return typeof navigator.credentials + ' ' + typeof window.PublicKeyCredential + ' ' + document.title", in: browser) as? String
        if credentials?.hasPrefix("undefined") == true {
            skip("autofill: this WebKit gives pages no navigator.credentials without the passkey entitlement, so there is no request to see (\(credentials ?? "")).")
        } else {
            check("autofill: a page asking for a passkey is seen", seen, credentials as Any)
        }
        check("autofill: Settings says whether passkeys can work in this build", !PasskeyAccess.status.isEmpty)
        if !PasskeyAccess.hasEntitlement {
            skip("autofill: passkeys with Touch ID need Apple's browser passkey entitlement, which this build is not signed with.")
        }

        // Settings → AutoFill.
        let settings = app.settingsWindow
        settings.show(.autofill)
        let pane = settings.autofillPane
        check("autofill: Settings has an AutoFill pane with the addresses and cards", await waitFor { pane.addresses.numberOfRows == 2 && pane.cards.numberOfRows == 2 },
              "\(pane.addresses.numberOfRows) \(pane.cards.numberOfRows)")
        pane.meCard = { AutofillAddress(fullName: "Ada Lovelace", street: "12 St James's Square", city: "London", postalCode: "SW1Y 4JH") }
        pane.addMeCard(nil)
        check("autofill: your card from Contacts is not added twice", await waitFor { pane.statusLabel.stringValue.contains("already") }, pane.statusLabel.stringValue)
        pane.addCard(nil)
        if let editor = pane.editor {
            editor.fields["number"]?.stringValue = "4242 4242 4242 4241"
            editor.done(nil)
            check("autofill: a mistyped card number is refused", editor.fields["number"]?.textColor == .systemRed)
            editor.dismiss(nil)
        }
        snapshot(settings.window, "autofill-settings")
        settings.window?.close()
        for card in (try? await vault.contents().cards) ?? [] { try? await vault.deleteCard(card.id) }
        for address in (try? await vault.contents().addresses) ?? [] { try? await vault.deleteAddress(address.id) }
    }
}
