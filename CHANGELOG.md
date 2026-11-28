# Changelog

What changed in each release of M365 Graph Cartographer. Versions follow [semantic versioning](https://semver.org/); the number lives in `data/version.json`.

## 1.0.0 (28 November 2026)

The first stable release. The map covers every Microsoft Graph v1.0 entity type, with 30 scenarios, a read-only script for each one, and the live read-only runner piloted on one scenario. Links and addresses from earlier versions still work.

### Changed

- The version number moves to 1.0.0. Nothing else changes from 0.11.0.
- The live runner on *Oversharing check before Copilot rollout* has been tested end to end in a tenant. It stays marked Preview while it covers one scenario.

## 0.11.0 (28 November 2026)

Preview: live read-only runner.

### New

- **Run this scenario (Preview), on one scenario:** *Oversharing check before Copilot rollout* gets a "Run this scenario" button. It opens a page of its own that runs the scenario's read-only steps against your own tenant and shows the results there: headline counts, a table, the raw JSON and Export CSV. Each step's results carry forward to the next with ticks, so you choose what goes on.
- **Sample data:** try every screen without a tenant or an app registration. The responses are made up, for a fictional organisation.
- **Read-only by design:** a guard checks every request before it is sent. Only reads to Microsoft Graph get through. Requests that could change data, such as applying a label, are never sent, and the run log shows each one as blocked.
- **Your own app registration, delegated permissions only:** you sign in as yourself, so MGC sees only what you can already see. Each step asks for its one read-only permission when it runs, and says why first. If the app has any permission that could change data, MGC stops and sends nothing.
- **Nothing is kept:** the access token and the results stay in the tab's memory. The page has no server, sends no analytics and involves no AI model.
- **Explained before you start:** a short explainer with two data-flow diagrams, a glossary, and a run log of every request. [How the live runner works](https://github.com/ThatM365Guy/M365-Graph-Cartographer/blob/main/docs/live-runner.md) is also linked from About.

### Changed

- The page now carries a Content Security Policy. It can only connect to Microsoft sign-in and Microsoft Graph, and it does so only when you sign in to the live runner.

## 0.10.0 (28 November 2026)

The first numbered release. It brings together everything on the live site so far and gives the page a proper header.

### New

- **Title and version:** the header now reads "M365 Graph Cartographer" with the version beside it. The version links here.
- **About:** an "i" button next to the version opens a short About popup: what the map is, who made it, and links to LinkedIn, the GitHub repository, the issue tracker and this changelog.
- **Icons:** each service bubble on the start ring has a simple outline icon above its API count, and Microsoft Graph at the centre has a network icon. They are generic symbols drawn for this map, not Microsoft logos.
- **Mark and tab icon:** a globe resting on a sextant's arc sits beside the title, in the About popup and in the browser tab.

### Already on the map

- Every Microsoft Graph v1.0 entity type (1,264) on the map: 16 services, 76 sub-services, 88 hand-written entries and generated entries for the rest, with permissions from Microsoft's catalogue marked "generated, not checked".
- Beta-only APIs, hidden until you switch them on under Filter.
- 30 scenarios in four groups (Classic, AI, Purview, Cost and hygiene), each with its HTTP calls, Microsoft Graph PowerShell and a read-only script to download.
- "Open in Graph Explorer" on every entry with a GET path, and permission names linked to graphpermissions.merill.net.
- A Coverage view, and a weekly scan of the Graph schema that flags what changed.
