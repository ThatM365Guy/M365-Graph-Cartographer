# Changelog

What changed in each release of M365 Graph Cartographer. Versions follow [semantic versioning](https://semver.org/); the number lives in `data/version.json`.

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
