import AppKit
import WebKit

/// #18 Picture in Picture, what is playing, the media keys, muting tabs.
extension FeatureSelfTest {

    func media() async {
        let player = first
        let center = app.mediaCenter
        player.window?.makeKeyAndOrderFront(nil)
        await open("/player", in: player)
        func playerJS(_ script: String) async -> Any? { await js(script, in: player) }
        var started = await playerJS("await document.getElementById('video').play(); await document.getElementById('tone').play(); return !document.getElementById('tone').paused") as? Bool
        if started != true {
            _ = await click("play", in: player)
            _ = await playerJS("await document.getElementById('video').play()")
            started = await playerJS("return !document.getElementById('tone').paused") as? Bool
        }
        check("media: (setup) the page plays", started == true)
        check("media: the tab knows it is playing sound, and video", await waitFor { player.media.isPlaying && player.media.isAudible && player.media.hasVideo },
              "\(player.media.isPlaying) \(player.media.isAudible) \(player.media.hasVideo)")
        check("media: …with the page's own title for it", player.media.title == "Fixture Tone" && player.media.artist == "The Test Band", player.media.title)
        check("media: a speaker shows on its tab", await waitFor { player.tabAccessory.hasSuffix("+sound") }, player.tabAccessory)
        check("media: the Picture in Picture button shows for a video", player.pictureInPictureItem?.isHidden == false)
        check("media: pages may go full screen", (await playerJS("return document.fullscreenEnabled")) as? Bool == true)

        // Another tab in front: the keys still go to the one playing.
        let quiet = app.newTab(beside: player, url: URL(string: site + "/page?title=Quiet")!, inFront: true)
        _ = await waitFor { quiet.window?.title == "Quiet" }
        quiet.window?.makeKeyAndOrderFront(nil)
        _ = await waitFor { self.front === quiet }
        check("media: what is playing is the tab playing, not the tab in front", center.current === player)
        check("media: the toolbar of the tab in front shows it", await waitFor { quiet.nowPlaying.title == "Fixture Tone" && quiet.nowPlayingItem?.isHidden == false },
              quiet.nowPlaying.title)
        snapshot(quiet.window, "media-now-playing")
        center.handle(.toggle)
        check("media: the play/pause key pauses the tab playing, from another tab", await waitFor {
            (await playerJS("return document.getElementById('tone').paused")) as? Bool == true
        })
        check("media: …which stays what the keys control", await waitFor { !player.media.isPlaying } && center.current === player)
        center.handle(.play)
        check("media: …and plays it again", await waitFor { (await playerJS("return !document.getElementById('tone').paused")) as? Bool == true })
        check("media: the page's media session is given next track", await waitFor { player.media.canSkip })
        center.handle(.next)
        check("media: …the next key calls it", await waitFor { ((await playerJS("return window.skipped")) as? NSNumber)?.intValue == 1 })
        quiet.nowPlaying.showTab(nil)
        check("media: its title in the toolbar shows the tab", await waitFor { self.front === player })

        // Muting.
        player.toggleMuteTab(nil)
        check("media: Mute Tab mutes it, WebKit's own mute, which the page cannot undo", await waitFor { player.media.isMuted && player.tabAccessory.hasSuffix("+muted") },
              player.tabAccessory)
        _ = await playerJS("document.getElementById('tone').muted = false; document.getElementById('tone').volume = 1")
        check("media: …even when the page unmutes its player", player.media.isMuted)
        player.toggleMuteTab(nil)
        check("media: …and unmutes it", await waitFor { !player.media.isMuted })
        quiet.window?.makeKeyAndOrderFront(nil)
        _ = await waitFor { self.front === quiet }
        app.muteBackgroundTabs(nil)
        check("media: Mute Background Tabs mutes those behind", await waitFor { player.media.isMuted })
        player.media.setMuted(false)

        // Picture in Picture.
        player.window?.makeKeyAndOrderFront(nil)
        _ = await waitFor { self.front === player }
        player.togglePictureInPicture(nil)
        check("media: Picture in Picture takes the video out of the page", await waitFor {
            ((await playerJS("return window.events")) as? [String] ?? []).contains("video:enterpictureinpicture")
        }, await playerJS("return window.events"))
        check("media: …and says so", await waitFor { player.media.isPictureInPicture })
        player.togglePictureInPicture(nil)
        check("media: …and puts it back", await waitFor { !player.media.isPictureInPicture })

        // Automatically, when another tab is chosen.
        BrowserSettings.automaticPictureInPicture = true
        _ = await playerJS("await document.getElementById('video').play()")
        _ = await waitFor { await player.media.isPlayingVideo() }
        // Straight after leaving it by hand: WebKit needs a moment (see TabMedia.pictureInPictureGap).
        quiet.window?.makeKeyAndOrderFront(nil)
        check("media: with the setting on, leaving a playing video takes it into Picture in Picture", await waitFor(8) { player.media.isPictureInPicture },
              "events \(await playerJS("return window.events.slice(-6)") as Any)")
        await pause(0.5)
        let stayedOut = (await playerJS("return document.getElementById('video').webkitPresentationMode")) as? String
        check("media: …where it stays", player.media.isPictureInPicture && stayedOut == "picture-in-picture", stayedOut)
        player.window?.makeKeyAndOrderFront(nil)
        check("media: …and coming back puts it in the page", await waitFor(8) { !player.media.isPictureInPicture })
        // Away and straight back: the video never leaves the page.
        quiet.window?.makeKeyAndOrderFront(nil)
        await pause(0.2)
        player.window?.makeKeyAndOrderFront(nil)
        await pause(2.5)
        let stayedIn = (await playerJS("return document.getElementById('video').webkitPresentationMode")) as? String
        check("media: back before it was out, it stays in the page", !player.media.isPictureInPicture && stayedIn == "inline", stayedIn)
        BrowserSettings.automaticPictureInPicture = false

        _ = await playerJS("document.querySelectorAll('video, audio').forEach(m => m.pause())")
        check("media: paused, the speaker goes", await waitFor { !player.tabAccessory.contains("sound") })
        quiet.window?.performClose(nil)
        await open("/second", in: player)
        check("media: a new page plays nothing", await waitFor { !player.media.isPlaying && !player.media.hasVideo })
    }
}
