import DeviceCore
import Testing

@Test func favoritesAddOnceAndForgetWhenRemoved() {
    var favorites = FavoritePaths(["/sdcard/DCIM"])
    favorites.add("/sdcard/DCIM")
    favorites.add("/sdcard/Music")
    #expect(favorites.paths == ["/sdcard/DCIM", "/sdcard/Music"])
    favorites.markMissing("/sdcard/Music")
    favorites.markMissing("/sdcard/NotAFavorite")
    #expect(favorites.missing == ["/sdcard/Music"])
    favorites.remove("/sdcard/Music")
    #expect(favorites.paths == ["/sdcard/DCIM"] && favorites.missing.isEmpty)
}

@Test func favoritesFollowARenameOfThemOrAFolderAbove() {
    var favorites = FavoritePaths(["/sdcard/A", "/sdcard/A/B", "/sdcard/AB", "/sdcard/C"])
    favorites.markMissing("/sdcard/A/B")
    favorites.followRename(from: "/sdcard/A", to: "/sdcard/Z")
    // "/sdcard/AB" only starts with the same letters: another folder.
    #expect(favorites.paths == ["/sdcard/Z", "/sdcard/Z/B", "/sdcard/AB", "/sdcard/C"])
    #expect(favorites.missing == ["/sdcard/Z/B"]) // the flag follows too
}

@Test func favoritesGoWithWhatWasDeleted() {
    var favorites = FavoritePaths(["/sdcard/A", "/sdcard/A/B", "/sdcard/AB"])
    favorites.markMissing("/sdcard/A/B")
    favorites.followDelete(["/sdcard/A"])
    #expect(favorites.paths == ["/sdcard/AB"] && favorites.missing.isEmpty)
}

@Test func lookingThemUpReplacesWhatsMissing() {
    var favorites = FavoritePaths(["/sdcard/A", "/sdcard/B"])
    favorites.markMissing("/sdcard/A")
    favorites.setMissing(["/sdcard/B", "/sdcard/Other"])
    #expect(favorites.missing == ["/sdcard/B"])
}
