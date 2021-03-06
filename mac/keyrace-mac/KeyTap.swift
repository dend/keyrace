// Created by Nat Friedman on 1/2/21.

import Foundation
import Accessibility
import Cocoa

func formatCount(count: Int) -> String {
    var str = ""

    if (count == 0) {
        str = "Waiting for first keystroke..."
    } else if (count == 1) {
        str = "👍 First key!"
    } else {
        var pfx = ""
        switch (count) {
        case 1..<500:       pfx = "👍 "
        case 500..<1000:    pfx = "🏃 "
        case 1000..<5000:   pfx = "💨 "
        case 5000..<10000:  pfx = "🙌 "
        case 10000..<20000: pfx = "🚀 "
        case 20000..<30000: pfx = "🥳 "
        case 30000...40000: pfx = "🔥 "
        case 40000...60000: pfx = "🤯 "
        default:
            pfx = ""
        }

        var sfx = ""
        if (count < 100) {
            sfx = " today"
        }
        str = "\(pfx)\(count) keys\(sfx)"
    }

    return str
}

func myCGEventCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let keyTap = Unmanaged<KeyTap>.fromOpaque(refcon!).takeUnretainedValue()

    if [.keyDown].contains(type) {
        var char = UniChar()
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 1, actualStringLength: &length, unicodeString: &char)
        keyTap.increment(char)

        keyTap.appDelegate.menubarItem?.statusBarItem.button?.title = formatCount(count: keyTap.keycount)
    }

    if [.tapDisabledByTimeout].contains(type) {
        keyTap.appDelegate.menubarItem?.statusBarItem.button?.title = "Lost event tap!"
    }

    return Unmanaged.passRetained(event)
}

struct Player: Codable {
    var username: String
    var gravatar: String
    var score: Int
}

class KeyTap {
    var appDelegate : AppDelegate
    var keycount = 0
    var lastDay = -1
    var lastMin = -1
    var timerRunning = false
    var keyTrapSetup = false
    var KEYRACE_HOST = "keyrace.app"
    var minutes = [Int](repeating:0, count:1440)
    var keys = [Int](repeating: 0, count:256)
    var leaderboardText = NSMutableAttributedString()

    init(_ appd: AppDelegate) {
        self.appDelegate = appd
    }

    func increment(_ keyCode: UInt16) {
        let date = Date()
        let calendar = Calendar.current

        // Reset to 0 at midnight
        let day = calendar.component(.day, from:date)
        if (lastDay != day) {
            lastDay = day
            keycount = 0
            keys = [Int](repeating:0, count:256)

            //  Clears our minutes, leaving the last 20 minutes, and than deletes the rest after 20 minutes
            minutes.replaceSubrange(0..<1420, with: repeatElement(0, count: 1420))
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1200), execute: {
                self.minutes.replaceSubrange(1420..<1440, with: repeatElement(0, count: 20))
            })
        }

        keycount += 1

        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        minutes[hour*60 + minute] += 1

        if keys.indices.contains(Int(keyCode)) {
            keys[Int(keyCode)] += 1
        } else {
            keys[Int(keyCode)] = 0
        }

        // Upload every minute
        if (lastMin != minute) {
            lastMin = minute
            uploadCount()
        }

        saveCount()
    }

    func getMinutesChart() -> [Int] {
        // Return the last 20 minutes minutely
        let date = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let min = calendar.component(.minute, from: date)
        let currMin = hour*60 + min

        var mins : [Int] = []
        for i in (0...20).reversed() {
            currMin - i > 0 ? mins.append(minutes[currMin - i]): mins.append(minutes[1440 + i - (20 - currMin)])
        }
        return mins
    }

    func getHoursChart() -> [Int] {
        var hours = [Int](repeating: 0, count: 24)

        for i in 0..<minutes.count {
            hours[i/60] += minutes[i]
        }

        return hours
    }

    func getKeysChart() -> [Int] {
        // Return key press counts for the lowercase alphabet
        return Array(keys[97...97+25])
    }

    func getSymbolsChart() -> [Int] {
        // Return key press counts for the the numbers
        return Array(keys[33...57])
    }

    func getLeaderboardText() -> NSMutableAttributedString {
        return leaderboardText
    }

    func uploadKeycount() {
        if appDelegate.gh?.token == nil {
            return
        }

        var url = URLComponents(string: "https://\(KEYRACE_HOST)/count")!
        url.queryItems = [
            URLQueryItem(name: "count", value: "\(keycount)")
        ]
        // Add the query to the URL if we are only supposed to show people they follow.
        if MenuSettings.getOnlyShowFollows() == NSControl.StateValue.on {
            url.queryItems?.append(URLQueryItem(name: "only_follows", value: "1"))
        }

        var request = URLRequest(url: url.url!)
        request.addValue("Bearer \(appDelegate.gh!.token!)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,                            // is there data
                let response = response as? HTTPURLResponse,  // is there HTTP response
                (200 ..< 300) ~= response.statusCode,         // is statusCode 2XX
                error == nil else {                           // was there no error, otherwise ...
                    print("Error uploading count \(error!)")
                    return
            }

            // Parse the JSON data for the leaderboard.
            self.parseJSON(json: data)
        }
        task.resume()
    }

    func parseJSON(json: Data) {
        let decoder = JSONDecoder()

        if let leaderboard = try? decoder.decode([Player].self, from: json) {
            // Re-initialize the leaderboard text.
            self.leaderboardText = NSMutableAttributedString()
            let attrBlankLine = NSMutableAttributedString(string: " \n")
            self.leaderboardText.append(attrBlankLine)

            // Add paragraph styling
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 8
            paragraphStyle.alignment = .justified
            self.leaderboardText.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: self.leaderboardText.length))
            // Add the tab stops so things are well aligned.
            paragraphStyle.tabStops = [NSTextTab(textAlignment: NSTextAlignment.left, location: 150, options: [:])]
            paragraphStyle.headIndent = 150

            for (i, player) in leaderboard.enumerated(){
                let fullUsername = "    @" + player.username
                var score = String(format: "\t%d", player.score)
                if i == 0 {
                    // They are the winner!
                    score += "   🎉"
                }
                // Add the new line.
                score += "\n"

                // Create the image for the avatar.
                var attrImage = NSMutableAttributedString()
                DispatchQueue.main.sync {
                    let url = URLComponents(string: player.gravatar)?.url
                    if let data = try? Data.init(contentsOf: url!, options: []) {
                        let avatar = NSImage(data: data)!
                        avatar.size = NSSizeFromString("20,20")
                        let circleAvatar = avatar.circle()
                        let attachment = NSTextAttachment()
                        let attachmentCell: NSTextAttachmentCell = NSTextAttachmentCell.init(imageCell: circleAvatar)
                        attachment.attachmentCell = attachmentCell
                        attrImage = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
                        attrImage.addAttribute(.baselineOffset, value: -6, range: .init(location: 0, length: 1))
                        attrImage.addAttribute(.link,
                                              value: NSURL(string: "https://github.com/"+player.username)!,
                                                  range: .init(location: 0, length: 1))
                    }
                }

                // Do the font styling for the line.
                let attrLine = NSMutableAttributedString(string: fullUsername + score)
                attrLine.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: NSRange(location: 0, length: fullUsername.count + score.count))
                let usernameRange = NSRange(location: 4, length: (fullUsername.count - 4))
                attrLine.addAttribute(.link,
                                      value: NSURL(string: "https://github.com/"+player.username)!,
                                          range: usernameRange)

                // Add the image.
                attrLine.replaceCharacters(in: NSRange(location: 0, length: 2), with: attrImage)
                self.leaderboardText.append(attrLine)
            }

            // Set the paragraph styling.
            self.leaderboardText.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: self.leaderboardText.length))
            self.leaderboardText.setAlignment(.justified, range: NSRange(location: 0, length: self.leaderboardText.length))
        }
    }

    func setupKeyTap() {
        if (keyTrapSetup) {
            return
        }

        loadCount()

        let eventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                              place: .headInsertEventTap,
                                              options: .defaultTap,
                                              eventsOfInterest: CGEventMask(eventMask),
                                              callback: myCGEventCallback,
                                              userInfo: refcon) else {
            NSLog("failed to create event tap; quitting")
            exit(1)
        }
        keyTrapSetup = true

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        appDelegate.menubarItem!.statusBarItem.button?.title = formatCount(count: keycount)

        uploadCount()
    }

    func uploadCount () {
        uploadKeycount()
    }

    func saveCount() {
        var filename = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".keyrace.tmp")

        var str = String(keycount)
        do {
            try str.write(to: filename, atomically: true, encoding: String.Encoding.utf8)
        } catch {
            NSLog("Could not write keycount to \(filename.path)")
            // failed to write file – bad permissions, bad filename, missing permissions, or more likely it can't be converted to the encoding
        }

        filename = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".keyrace.minutes.tmp")
        let minStrings = minutes.map({ String($0) })
        str = minStrings.joined(separator: ",")
        do {
            try str.write(to: filename, atomically: true, encoding: String.Encoding.utf8)
        } catch {
            NSLog("Could not write keycount to \(filename.path)")
            // failed to write file – bad permissions, bad filename, missing permissions, or more likely it can't be converted to the encoding
        }

        filename = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".keyrace.histogram.tmp")
        let keyStrings = keys.map({ String($0) })
        str = keyStrings.joined(separator: ",")
        do {
            try str.write(to: filename, atomically: true, encoding: String.Encoding.utf8)
        } catch {
            NSLog("Could not write histogram to \(filename.path)")
            // failed to write file – bad permissions, bad filename, missing permissions, or more likely it can't be converted to the encoding
        }

    }

    func loadCount() {
        let date = Date()
        let calendar = Calendar.current
        let day = calendar.component(.day, from: date)
        let month = calendar.component(.month, from:date)

        // Load the total daily count
        var filename = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".keyrace.tmp")
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: filename.path)
            let mtime = attr[FileAttributeKey.modificationDate] as! Date
            lastDay = calendar.component(.day, from:mtime)
            let lastMonth = calendar.component(.month, from:mtime)

            if (lastDay == day && lastMonth == month) {
                let str = try String(contentsOf: filename, encoding: .utf8)
                keycount = Int(str) ?? 0
            }
        } catch { }

        // Load the hourly histogram
        filename = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".keyrace.minutes.tmp")
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: filename.path)
            let mtime = attr[FileAttributeKey.modificationDate] as! Date
            let lastDay = calendar.component(.day, from:mtime)
            let lastMonth = calendar.component(.month, from:mtime)

            if (lastDay == day && lastMonth == month) {
                let str = try String(contentsOf: filename, encoding: .utf8)
                let minStr = str.split(separator: ",")
                minutes = minStr.map { x in return Int(x) ?? 0 }
            }
        } catch { }

        // Load the key histogram
        filename = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".keyrace.histogram.tmp")
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: filename.path)
            let mtime = attr[FileAttributeKey.modificationDate] as! Date
            let lastDay = calendar.component(.day, from:mtime)
            let lastMonth = calendar.component(.month, from:mtime)

            if (lastDay == day && lastMonth == month) {
                let str = try String(contentsOf: filename, encoding: .utf8)
                let keyStr = str.split(separator: ",")
                keys = keyStr.map { x in return Int(x) ?? 0 }
            }
        } catch { }


    }

    func getAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true]
        var isAppTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary?)
        if (isAppTrusted) {
            self.setupKeyTap()
            return
        }

        // Wait for the user to give us permission
        if (timerRunning) { return }
        self.timerRunning = true
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: false]
            isAppTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary?)
            if (isAppTrusted) {
                self.setupKeyTap()
                timer.invalidate()
                self.timerRunning = false
            }
        }
    }
}
