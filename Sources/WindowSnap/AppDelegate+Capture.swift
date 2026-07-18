import Cocoa
import Vision

extension AppDelegate {
    func captureThenAnnotate(_ args: [String], path: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = args + [path]
            do { try p.run(); p.waitUntilExit() } catch {
                Logger.log("Screenshot failed — \(error.localizedDescription)")
                return
            }
            guard FileManager.default.fileExists(atPath: path),
                  let img = NSImage(contentsOfFile: path) else { return }   // Esc
            DispatchQueue.main.async {
                Logger.log("Screenshot → \((path as NSString).lastPathComponent) (+clipboard)")
                self.deliverCapture(img, filePath: path)
            }
        }
    }

    /// Shared post-capture delivery: copy to the clipboard (memory buffer),
    /// open the shot in the Annotate tab, and show the Quick Access Overlay
    /// (drag-out / Save / Pin / auto-close).
    func deliverCapture(_ img: NSImage, filePath: String?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])

        if let path = filePath {
            settingsWindow.showAnnotate(path: path)
        } else {
            settingsWindow.showAnnotateFromClipboard(img)
        }
        QuickAccessOverlay.present(image: img, filePath: filePath) { [weak self] in
            // Thumbnail click re-focuses the annotator.
            if let path = filePath { self?.settingsWindow.showAnnotate(path: path) }
            else { self?.settingsWindow.show() }
        }
    }

    /// Interactive area capture through WindowSnap's own region selector (which
    /// shows the magnifier + live dimensions), then deliver to Annotate.
    func captureAreaViaSelector(toFile: Bool) {
        RegionSelector.shared.begin { [weak self] cgRect in
            guard let self = self, let rect = cgRect, let img = ScreenGrab.image(rect) else { return }
            Settings.shared.lastCaptureRect =
                "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
            Settings.shared.save()
            if toFile, let path = self.saveImageToDownloads(img) {
                Logger.log("Screenshot area → \((path as NSString).lastPathComponent)")
                self.deliverCapture(img, filePath: path)
            } else {
                Logger.log("Screenshot area → clipboard")
                self.deliverCapture(img, filePath: nil)
            }
        }
    }

    /// Writes an image to Downloads as "Screenshot <date>.png", returning its path.
    func saveImageToDownloads(_ img: NSImage) -> String? {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let url = dir.appendingPathComponent("Screenshot \(fmt.string(from: Date())).png")
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        do { try png.write(to: url, options: .atomic); return url.path }
        catch { Logger.log("Area save failed — \(error.localizedDescription)"); return nil }
    }

    /// Re-captures the last user-selected region ("Capture Previous Area").
    /// With no stored region yet, asks for one first.
    func capturePreviousArea() {
        let parts = Settings.shared.lastCaptureRect.components(separatedBy: ",").compactMap { Int($0) }
        if parts.count == 4 {
            let rect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            guard let img = ScreenGrab.image(rect) else { NSSound.beep(); return }
            Logger.log("Screenshot previous area → clipboard")
            deliverCapture(img, filePath: nil)
            return
        }
        RegionSelector.shared.begin { [weak self] cgRect in
            guard let rect = cgRect else { return }
            Settings.shared.lastCaptureRect =
                "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
            Settings.shared.save()
            guard let img = ScreenGrab.image(rect) else { NSSound.beep(); return }
            Logger.log("Screenshot area → clipboard")
            self?.deliverCapture(img, filePath: nil)
        }
    }

    /// Captures directly to the clipboard (memory buffer) — no file written —
    /// and presents the Quick Access Overlay. Detects Esc via the pasteboard
    /// change count so a cancelled capture doesn't show a stale image.
    func captureToClipboardThenAnnotate(_ args: [String]) {
        let before = NSPasteboard.general.changeCount
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = args + ["-c"]
            do { try p.run(); p.waitUntilExit() } catch {
                Logger.log("Screenshot failed — \(error.localizedDescription)")
                return
            }
            DispatchQueue.main.async {
                // Unchanged clipboard means the user pressed Esc.
                guard NSPasteboard.general.changeCount != before,
                      let img = NSImage(pasteboard: .general) else { return }
                Logger.log("Screenshot → clipboard")
                self.deliverCapture(img, filePath: nil)
            }
        }
    }

    /// CleanShot-style "Hide Desktop Icons": toggles Finder's desktop drawing.
    func toggleDesktopIcons() {
        let finderDefaults = UserDefaults(suiteName: "com.apple.finder")
        let visible = finderDefaults?.object(forKey: "CreateDesktop") as? Bool ?? true
        runProcess("/usr/bin/defaults",
                   ["write", "com.apple.finder", "CreateDesktop", "-bool", visible ? "false" : "true"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.runProcess("/usr/bin/killall", ["Finder"])
        }
        Logger.log("Desktop icons \(visible ? "hidden" : "shown")")
    }

    // MARK: - Screen OCR (copy text from anything on screen)

    /// Interactive region OCR: the native crosshair selection (screencapture -i)
    /// grabs a region to a temp file, Vision recognizes the text, and the result
    /// lands on the clipboard. Pressing Esc during selection cancels silently.
    @objc func ocrScreenRegion() {
        let path = NSTemporaryDirectory() + "windowsnap-ocr-\(UUID().uuidString).png"
        DispatchQueue.global(qos: .userInitiated).async {
            // -i: interactive selection, -x: no camera sound. Blocks until the
            // user finishes or cancels, so this runs off the main thread.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", path]
            do { try p.run(); p.waitUntilExit() } catch {
                Logger.log("OCR: capture failed — \(error.localizedDescription)")
                return
            }
            defer { try? FileManager.default.removeItem(atPath: path) }

            // No file means the user pressed Esc — not an error.
            guard let img = NSImage(contentsOfFile: path),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request]) } catch {
                Logger.log("OCR: recognition failed — \(error.localizedDescription)")
                return
            }
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")

            DispatchQueue.main.async {
                guard !text.isEmpty else {
                    LayoutManager.notify("No text found", "The selected area had no readable text.")
                    Logger.log("OCR: no text found")
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                LayoutManager.notify("Text copied", "\(text.count) characters on the clipboard")
                Logger.log("OCR: copied \(text.count) chars")
            }
        }
    }

    /// Single restore entry point shared by the hotkey and (indirectly) the UI.
    /// Resolves the layout fresh and restores on the main thread. Handles pinned
    /// layouts (separate stores) as well as saved layouts.
}
