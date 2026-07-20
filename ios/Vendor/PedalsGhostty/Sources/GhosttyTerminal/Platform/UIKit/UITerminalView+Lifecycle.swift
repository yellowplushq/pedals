//
//  UITerminalView+Lifecycle.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(UIKit)
    import QuartzCore
    import UIKit

    extension UITerminalView {
        func setupApplicationLifecycleObservers() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applicationDidEnterBackground),
                name: UIApplication.didEnterBackgroundNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applicationDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
        }

        func syncApplicationActiveState() {
            core.setApplicationActive(
                UIApplication.shared.applicationState == .active
            )
        }

        @objc func applicationDidEnterBackground(_: Notification) {
            TerminalDebugLog.log(.lifecycle, "application did enter background")
            stopMomentumScrolling(sendTerminalEndEvent: false)
            core.setApplicationActive(false)
        }

        @objc func applicationDidBecomeActive(_: Notification) {
            TerminalDebugLog.log(.lifecycle, "application did become active")
            updateDisplayScale()
            updateColorScheme()
            core.setApplicationActive(true)
        }

        override open func didMoveToWindow() {
            super.didMoveToWindow()
            TerminalDebugLog.log(
                .lifecycle,
                "didMoveToWindow attached=\(window != nil)"
            )
            updateDisplayScale()
            if window != nil {
                core.rebuildIfReady()
                updateColorScheme()
                core.startDisplayLink()
                // Defer sublayer frame and metrics sync to the next runloop
                // so that AutoLayout has resolved final bounds.
                DispatchQueue.main.async { [weak self] in
                    guard let self, window != nil else { return }
                    updateSublayerFrames()
                    core.fitToSize()
                }
            } else {
                core.stopDisplayLink()
                core.freeSurface()
            }
        }

        override open func layoutSubviews() {
            super.layoutSubviews()
            TerminalDebugLog.log(
                .metrics,
                "layoutSubviews bounds=\(NSCoder.string(for: bounds))"
            )
            updateSublayerFrames()
            core.fitToSize()
        }

        func resolvedDisplayScale() -> CGFloat {
            if let screen = window?.screen {
                return screen.nativeScale
            }
            if traitCollection.displayScale > 0 {
                return traitCollection.displayScale
            }
            return UIScreen.main.nativeScale
        }

        func updateDisplayScale() {
            let scale = resolvedDisplayScale()
            TerminalDebugLog.log(
                .metrics,
                "updateDisplayScale scale=\(String(format: "%.2f", scale))"
            )
            contentScaleFactor = scale
            layer.contentsScale = scale
            updateSublayerFrames()
        }

        func updateSublayerFrames() {
            let scale = resolvedDisplayScale()
            contentScaleFactor = scale
            layer.contentsScale = scale
            enforceSublayerScale()
            syncSublayerScaleObservations()
        }

        func enforceSublayerScale() {
            let scale = resolvedDisplayScale()
            guard let sublayers = layer.sublayers else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            for sublayer in sublayers {
                if sublayer.contentsScale != scale {
                    sublayer.contentsScale = scale
                }
                if sublayer.frame != bounds {
                    sublayer.frame = bounds
                }
            }
        }

        /// Ghostty's IOSurfaceLayer rewrites its own `contentsScale` when an
        /// asynchronously drawn frame lands after this view has resized (it
        /// stretches the stale frame to fit rather than dropping it). Its
        /// renderer then derives the next frame size from bounds × that
        /// adjusted scale, so one late frame parks the surface in a
        /// self-consistently mis-scaled state with no event left to heal it.
        ///
        /// This view owns the display scale. Observe external writes and
        /// answer each one by re-asserting the native scale and requesting a
        /// render pass, which replaces the stale frame at the correct size.
        func syncSublayerScaleObservations() {
            let sublayers = layer.sublayers ?? []
            var seen = Set<ObjectIdentifier>()
            for sublayer in sublayers {
                let id = ObjectIdentifier(sublayer)
                seen.insert(id)
                guard sublayerScaleObservations[id] == nil else { continue }
                sublayerScaleObservations[id] = sublayer.observe(
                    \.contentsScale
                ) { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        self?.correctExternalSublayerScaleIfNeeded()
                    }
                }
            }
            for id in sublayerScaleObservations.keys where !seen.contains(id) {
                sublayerScaleObservations[id]?.invalidate()
                sublayerScaleObservations.removeValue(forKey: id)
            }
        }

        func correctExternalSublayerScaleIfNeeded() {
            let scale = resolvedDisplayScale()
            guard let sublayers = layer.sublayers,
                  sublayers.contains(where: {
                      $0.contentsScale != scale || $0.frame != bounds
                  })
            else { return }

            TerminalDebugLog.log(
                .metrics,
                "correcting externally adjusted sublayer scale to \(String(format: "%.2f", scale))"
            )
            enforceSublayerScale()
            core.requestImmediateTick()
        }

        public func fitToSize() {
            core.fitToSize()
        }

        /// Schedule one render pass without resynchronizing surface metrics.
        /// Hosts that have already parsed new terminal bytes should use this
        /// instead of `fitToSize()`; view layout remains the sole owner of
        /// pixel-size changes.
        public func requestRender() {
            core.requestImmediateTick()
        }

        override open func traitCollectionDidChange(
            _ previousTraitCollection: UITraitCollection?
        ) {
            super.traitCollectionDidChange(previousTraitCollection)
            updateDisplayScale()
            if traitCollection.hasDifferentColorAppearance(
                comparedTo: previousTraitCollection
            ) {
                updateColorScheme()
            }
        }

        func updateColorScheme() {
            let style = traitCollection.userInterfaceStyle
            let scheme: TerminalColorScheme = style == .dark ? .dark : .light
            TerminalDebugLog.log(.lifecycle, "updateColorScheme scheme=\(scheme)")
            surface?.setColorScheme(scheme.ghosttyValue)
            if let controller,
               let viewState = delegate as? TerminalViewState,
               viewState.controller === controller
            {
                viewState.adopt(terminalColorScheme: scheme)
            } else {
                controller?.setColorScheme(scheme)
            }
        }

        @discardableResult
        override open func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            core.setFocus(true)
            onFocusChange?(true)
            return result
        }

        @discardableResult
        override open func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            core.setFocus(false)
            onFocusChange?(false)
            return result
        }
    }
#endif
