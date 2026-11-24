# Polling Duty Attendance App (GitHub Pages + Supabase)

Static front end on GitHub Pages with **Supabase PostgreSQL** backend. Pre-loaded with **491 Polling Stations (2,946 staff)** and **633 Reserve Staff** from `MPL_PO-APO-OPO.xlsx`.

## Key Features & Updates
- **Polling Station Numbers (`Ward/PS` format, e.g., `40/2`)**: All team/group numbers replaced with Polling Station numbers across Capture, Reports, Reserve Assignment, Disbursement, Dashboard, LED Displays, Excel Export, and Supabase Views.
- **Roll Back Attendance (`admin` & `user`)**: If attendance is captured wrongly, Admins and Users can roll it back to *Absent (not reported)* from either **Capture Attendance** or **Reports** (logged in `audit_log`; assigned reserve staff must be unassigned first).
- **RO Disbursement Updates**: Returning Officers (`ro`) can update disbursement/distribution stages exclusively for their allotted Polling Stations.
- **Database Wipe Protection**: Clearing the entire database and "Replace completely (clears attendance)" are disabled in both the UI and Supabase API.

## 1. Create the Supabase Database
1. Go to [supabase.com](https://supabase.com) and click **New Project** (choose **Mumbai** region for low latency; save your database password).
2. In the left sidebar, open **SQL Editor → New query**.
3. Copy the entire contents of `supabase_setup.sql`, paste it into the editor, and click **Run** (`Success. No rows returned` is expected).
4. Go to **Project Settings → API** and copy:
   - **Project URL** (e.g. `https://abcdefgh.supabase.co`)
   - **anon / publishable key**

## 2. Link Supabase & Publish on GitHub Pages
1. Open `config.js` and paste your `SUPABASE_URL` and `SUPABASE_ANON_KEY`.
2. Create a new GitHub repository and upload all files from this folder to the repository root.
3. Go to **Settings → Pages → Build and deployment**, select **Deploy from a branch**, choose `main` and `/ (root)`, and click **Save**.
4. Open your GitHub Pages URL, log in as `admin` / `admin123`, and immediately change the admin password under **Admin → Users**.
5. Go to **Admin → Database & reports** and click **Save employee data to database** so the live Supabase report views (`report_team`, `report_summary`, `report_reserve`) populate immediately.

## Roles
| Role | Permissions |
|---|---|
| `admin` | Capture & roll back attendance, assign reserve, update disbursement, geofence, manage users, merge employee Excel updates |
| `user` | Capture & roll back attendance (polling station / reserve), reports, dashboard, disbursement (view) |
| `ro` | Reports, dashboard, and **update disbursement status** for allotted polling stations only |
| `sec` | Assign attended reserve staff to polling stations, update disbursement, reports, dashboard |
| `dist` | Update disbursement status, reports, dashboard |
| `display` | Full-screen LED dashboards (`team-dashboard.html`, `reserve-dashboard.html`) |
