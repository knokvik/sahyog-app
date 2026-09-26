**Sahyog phone app**

This is the JanRakshak app people carry. A citizen can ask for help. A volunteer can see work and the map. A coordinator can watch the ground. If the network drops, the SOS stays on the phone and can hop to a nearby phone over Bluetooth until someone has a signal.

The release build talks to `https://sahyog-new.onrender.com`.

**Who sees which screens**

The app is one install. After sign-in with Clerk, the tabs follow the role.

A citizen sees:

- **Dashboard** — hold to send an SOS, a small map, and motion detection that can start a countdown if the phone falls, crashes, is shaken hard, or stays still after an impact
- **Map** — incidents and people on OpenStreetMap
- **Missing** — report someone missing, with a photo, and see the board
- **Profile** — their own details

A new citizen is asked to finish phone, blood group, and address before those tabs open.

A volunteer sees:

- **Dashboard** — the same SOS tools, plus the role they are signed in as
- **Map**
- **SOS** — alerts nearby, and an arrow that opens turn-by-turn directions in Google Maps on Android
- **Tasks** — work assigned to them, including proof photos
- **Profile**

A coordinator sees:

- **Dashboard** — counts, recent work, and SOS
- **Map**
- **Operations** — volunteers, tasks, and needs
- **SOS** — the live alert list, acknowledge, and directions
- **Profile**

**What the phone does on its own**

- Saves an SOS in SQLite first, then syncs when the network returns
- Shouts the same SOS over Bluetooth so a neighbor's phone can carry it
- Sends a photo only after it has been uploaded, so the other role sees a real link, with a loader while it downloads
- Keeps one SOS countdown at a time, so a motion alert and the hold button do not both fire
- Leaves Bluetooth mesh off on anything that is not Android, because Nearby Connections is Android-only
- Uses easier motion limits while you are testing, and stricter ones in production mode

**How it talks to the server**

Sign-in goes through Clerk. Every later call sends that token.

The calls you will notice in the app:

- `POST /api/auth/sync` and `GET /api/users/me` — who you are
- `POST /api/v1/sos` and `PUT /api/v1/sos/:id/cancel` — raise or cancel help
- `POST /api/v1/mesh/sync` — deliver a packet that arrived over Bluetooth
- `POST /api/v1/locations/update` — share where you are while on duty
- `POST /api/v1/missing` and `PATCH /api/v1/missing/:id/found` — missing-person reports
- `GET /api/v1/tasks/...` and `PATCH /api/v1/tasks/:id/status` — a volunteer's work and proof
- `POST /api/v1/uploads/task-proof` — the photo upload used by reports and tasks
- A socket on the same server for live SOS alerts

**How to run it**

- Flutter, on the `cool-features` line if you want the latest phone fixes
- `flutter pub get`
- A debug run uses your machine on port 3000
- A release APK uses the Render server above
- For this phone, build with `flutter build apk --release --target-platform android-arm64` and install with adb

Directions on Android open the Google Maps app already in navigation, not just a web link.
