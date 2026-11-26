import Foundation

/// The updater downloads the newest release, also when an older one is already waiting.
func updateVersionTests() {
    check(UpdateVersion.newer("0.1.10", than: "0.1.9"), "versions compare as numbers, not text")
    check(!UpdateVersion.newer("0.1.63", than: "0.1.63"), "the same version is not newer")
    check(UpdateVersion.wanted(latest: "0.1.66", running: "0.1.63", waiting: nil), "a newer release is downloaded")
    check(!UpdateVersion.wanted(latest: "0.1.63", running: "0.1.63", waiting: nil), "up to date: nothing to download")
    // Seen on a Mac open for six days: 0.1.66 waited while 0.1.69 to 0.1.72 came out, and
    // Restart to update would have installed 0.1.66.
    check(UpdateVersion.wanted(latest: "0.1.72", running: "0.1.63", waiting: "0.1.66"), "a release newer than the waiting update replaces it")
    check(!UpdateVersion.wanted(latest: "0.1.66", running: "0.1.63", waiting: "0.1.66"), "the waiting update is not downloaded again")
}
