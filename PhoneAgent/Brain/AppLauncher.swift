import Foundation

/// An app the Fast agent can open from the Home Screen by its label, with the names a request may use.
struct LaunchTarget: Hashable, Sendable {
    let id: String
    let name: String
    let aliases: [String]
}

/// The app catalog FastPaths and BrainBrief resolve app names against.
enum AppLauncher {
    static let catalog: [LaunchTarget] = [
        LaunchTarget(id: "whatsapp", name: "WhatsApp", aliases: ["whats app", "واتساب", "واتس اب"]),
        LaunchTarget(id: "settings", name: "Settings", aliases: ["preferences", "الإعدادات", "الاعدادات"]),
        LaunchTarget(id: "wifi", name: "Wi-Fi settings", aliases: ["wifi", "wireless", "واي فاي"]),
        LaunchTarget(id: "bluetooth", name: "Bluetooth settings", aliases: ["bluetooth", "بلوتوث"]),
        LaunchTarget(id: "phone", name: "Phone", aliases: ["dialer", "calls", "الهاتف", "المكالمات"]),
        LaunchTarget(id: "messages", name: "Messages", aliases: ["sms", "imessage", "texts", "الرسائل"]),
        LaunchTarget(id: "mail", name: "Mail", aliases: ["email", "inbox", "البريد"]),
        LaunchTarget(id: "safari", name: "Safari", aliases: ["browser", "web", "سفاري", "المتصفح"]),
        LaunchTarget(id: "maps", name: "Maps", aliases: ["apple maps", "الخرائط"]),
        LaunchTarget(id: "music", name: "Music", aliases: ["apple music", "الموسيقى"]),
        LaunchTarget(id: "photos", name: "Photos", aliases: ["gallery", "pictures", "الصور"]),
        LaunchTarget(id: "calendar", name: "Calendar", aliases: ["schedule", "التقويم"]),
        LaunchTarget(id: "clock", name: "Clock", aliases: ["alarm", "timer", "الساعة", "المنبه"]),
        LaunchTarget(id: "notes", name: "Notes", aliases: ["apple notes", "الملاحظات"]),
        LaunchTarget(id: "reminders", name: "Reminders", aliases: ["todo", "to-do", "التذكيرات"]),
        LaunchTarget(id: "appstore", name: "App Store", aliases: ["store", "متجر التطبيقات"]),
        LaunchTarget(id: "youtube", name: "YouTube", aliases: ["يوتيوب"]),
        LaunchTarget(id: "instagram", name: "Instagram", aliases: ["insta", "انستغرام", "انستقرام"]),
        LaunchTarget(id: "x", name: "X", aliases: ["twitter", "tweet", "تويتر"]),
        LaunchTarget(id: "telegram", name: "Telegram", aliases: ["تيليجرام", "تلغرام"]),
        LaunchTarget(id: "snapchat", name: "Snapchat", aliases: ["snap", "سناب شات", "سناب"]),
        LaunchTarget(id: "spotify", name: "Spotify", aliases: ["سبوتيفاي"]),
        LaunchTarget(id: "googlemaps", name: "Google Maps", aliases: ["خرائط جوجل"]),
        LaunchTarget(id: "uber", name: "Uber", aliases: ["ride", "taxi", "أوبر"]),
        LaunchTarget(id: "shortcuts", name: "Shortcuts", aliases: ["الاختصارات"]),
        LaunchTarget(id: "files", name: "Files", aliases: ["documents", "الملفات"]),
        LaunchTarget(id: "facetime", name: "FaceTime", aliases: ["video call", "فيس تايم"]),
        LaunchTarget(id: "wallet", name: "Wallet", aliases: ["apple pay", "cards", "المحفظة"]),
        LaunchTarget(id: "health", name: "Health", aliases: ["steps", "الصحة"]),
        LaunchTarget(id: "gmail", name: "Gmail", aliases: ["google mail", "جيميل"]),
        LaunchTarget(id: "slack", name: "Slack", aliases: ["سلاك"]),
        LaunchTarget(id: "zoom", name: "Zoom", aliases: ["zoom meeting", "زوم"]),
    ]

    static func target(id: String) -> LaunchTarget? { catalog.first { $0.id == id } }
}
