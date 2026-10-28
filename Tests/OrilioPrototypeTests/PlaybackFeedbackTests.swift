// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OrilioPrototype

struct ControlFeedbackTests {
    @Test func clickShowsTheRequestedStateUntilTheSourceConfirms() {
        var feedback = ControlFeedback()
        let started1 = feedback.begin(.playPause, expectingPlaying: true)
        #expect(started1)
        #expect(feedback.isPlaying(actual: false)) // immediate response
        feedback.finish(.playPause, error: nil)
        feedback.confirm(playing: false) // an older report: the guess stays
        #expect(feedback.isPlaying(actual: false))
        feedback.confirm(playing: true)
        #expect(feedback.expectedPlaying == nil)
    }

    @Test func rapidClicksSendOnce() {
        var feedback = ControlFeedback()
        let started2 = feedback.begin(.skip)
        #expect(started2)
        let started3 = feedback.begin(.skip)
        #expect(!started3)
        let started4 = feedback.begin(.playPause, expectingPlaying: false)
        #expect(started4)
        feedback.finish(.skip, error: nil)
        let started5 = feedback.begin(.skip)
        #expect(started5)
    }

    @Test func failureRollsBackAndExplains() {
        var feedback = ControlFeedback()
        _ = feedback.begin(.playPause, expectingPlaying: true)
        feedback.finish(.playPause, error: "Spotify isn't responding")
        #expect(!feedback.isPlaying(actual: false))
        #expect(feedback.failure == "Spotify isn't responding")
        _ = feedback.begin(.skip)
        #expect(feedback.failure == nil) // a new attempt clears the old message
    }

    @Test func unconfirmedGuessExpiresButNotWhileInFlight() {
        var feedback = ControlFeedback()
        _ = feedback.begin(.playPause, expectingPlaying: true)
        feedback.expire()
        #expect(feedback.expectedPlaying == true) // still waiting for the source to answer
        feedback.finish(.playPause, error: nil)
        feedback.expire()
        #expect(feedback.expectedPlaying == nil)
    }

    @Test func errorMessagesNameTheSource() {
        #expect(ControlFeedback.message(for: .failed("The app did not respond"), source: "Spotify") == "Spotify isn't responding")
        #expect(ControlFeedback.message(for: .notRunning, source: "Music") == "Music isn't running")
        #expect(ControlFeedback.message(for: .permissionDenied, source: "Music") == "Orilio isn't allowed to control Music")
    }
}

struct PlaybackIndicatorTests {
    private func session(_ state: PlaybackState, buffering: Bool = false) -> MediaSessionSnapshot {
        MediaSessionSnapshot(sourceID: "s", providerID: "p", sourceName: "S", title: "T", artist: nil, album: nil,
                             artworkURL: nil, state: state, duration: nil, position: nil, positionDate: Date(),
                             capabilities: .playPause, updatedAt: Date(), expiresAt: nil, isBuffering: buffering)
    }

    @Test func modeFollowsStateAndExpectation() {
        #expect(EqualizerView.Mode(session(.playing)) == .playing)
        #expect(EqualizerView.Mode(session(.paused)) == .paused)
        #expect(EqualizerView.Mode(session(.playing, buffering: true)) == .buffering)
        #expect(EqualizerView.Mode(session(.paused), expectedPlaying: true) == .playing) // reacts to the click
        #expect(EqualizerView.Mode(session(.playing), expectedPlaying: false) == .paused)
    }

    @Test func bufferingOnlyCountsWhilePlaying() throws {
        var message = BridgeMessage(type: "session", tabId: 1)
        message.state = "paused"
        message.title = "T"
        message.buffering = true
        #expect(try #require(message.snapshot(providerID: "chrome", receivedAt: Date())).isBuffering == false)
        message.state = "playing"
        #expect(try #require(message.snapshot(providerID: "chrome", receivedAt: Date())).isBuffering == true)
    }
}

struct ArtworkDecodingTests {
    @Test func coversAreDownsampledForDisplay() throws {
        let context = try #require(CGContext(data: nil, width: 1_000, height: 1_000, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_000, height: 1_000))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let cover = try #require(ArtworkCache.decode(data as Data))
        #expect(max(cover.image.width, cover.image.height) <= ArtworkCache.maxPixelSize)
        #expect(ArtworkCache.decode(Data("not an image".utf8)) == nil)
    }
}
