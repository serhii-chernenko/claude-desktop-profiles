import Foundation

if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run())
}

ClaudeProfilesApp.main()
