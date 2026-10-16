import AppKit
import Darwin

/// Acquired before Model opens the shared database.
enum SingleInstance {
 private static var descriptor: Int32 = -1
 static func acquire() {
  let bundleID = Bundle.main.bundleIdentifier ?? "local.MeetingAssistant"
  if let existing = NSRunningApplication.runningApplications(withBundleIdentifier:bundleID).first(where:{$0.processIdentifier != getpid() && !$0.isTerminated}) {
   existing.activate(options:[.activateAllWindows]); exit(0)
  }
  let folder = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("MeetingAssistant")
  do { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true) }
  catch { fputs("Cannot establish application lock\n",stderr); exit(1) }
  descriptor = open(folder.appendingPathComponent("instance.lock").path,O_CREAT | O_RDWR,0o600)
  guard descriptor >= 0, flock(descriptor,LOCK_EX | LOCK_NB) == 0 else { exit(0) }
  // Process exit releases the lock, including crash termination.
 }
}
