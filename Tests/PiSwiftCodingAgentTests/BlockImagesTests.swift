import Foundation
import Testing
@testable import PiSwiftCodingAgent

// MARK: - SettingsManager blockImages tests

@Test func blockImagesDefaultsToFalse() {
    let manager = SettingsManager.inMemory()
    #expect(manager.getBlockImages() == false)
}

@Test func blockImagesReturnsTrueWhenSet() {
    var settings = Settings()
    settings.images = ImageSettings(autoResize: nil, blockImages: true)
    let manager = SettingsManager.inMemory(settings)
    #expect(manager.getBlockImages() == true)
}

@Test func blockImagesPersistsViaSetBlockImages() {
    let manager = SettingsManager.inMemory()
    #expect(manager.getBlockImages() == false)

    manager.setBlockImages(true)
    #expect(manager.getBlockImages() == true)

    manager.setBlockImages(false)
    #expect(manager.getBlockImages() == false)
}

@Test func blockImagesHandlesAlongsideAutoResize() {
    var settings = Settings()
    settings.images = ImageSettings(autoResize: true, blockImages: true)
    let manager = SettingsManager.inMemory(settings)
    #expect(manager.getAutoResizeImages() == true)
    #expect(manager.getBlockImages() == true)
}

@Test func blockImagesWithNilImageSettings() {
    var settings = Settings()
    settings.images = nil
    let manager = SettingsManager.inMemory(settings)
    #expect(manager.getBlockImages() == false)
}

@Test func setBlockImagesCreatesImageSettingsIfNil() {
    let manager = SettingsManager.inMemory()
    // Initially no image settings
    manager.setBlockImages(true)
    #expect(manager.getBlockImages() == true)
}

// MARK: - ImageSettings tests

@Test func imageSettingsCanBeCreated() {
    let settings = ImageSettings(autoResize: true, blockImages: false)
    #expect(settings.autoResize == true)
    #expect(settings.blockImages == false)
}

@Test func imageSettingsAllowsNilValues() {
    let settings = ImageSettings(autoResize: nil, blockImages: nil)
    #expect(settings.autoResize == nil)
    #expect(settings.blockImages == nil)
}
