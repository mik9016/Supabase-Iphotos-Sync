# IPhotos Sync

A simple iOS app to backup photos from your iPhone to Supabase Storage. Photos are uploaded (oldest first) and then deleted from your device to free up space.

## Features

- Sync photos and videos to Supabase Storage
- Auto mode: automatically selects oldest photos
- Manual mode: pick which photos to sync
- TUS resumable uploads for large videos (handles interruptions)
- Stores photo metadata (date, location, dimensions) in database
- Works with self-hosted Supabase or Supabase Cloud

## Requirements

- iOS 16.0+
- Xcode 15+
- Supabase instance (self-hosted or cloud)

---

## Installation (Without Apple Developer Account)

You can install this app on your iPhone without a paid Apple Developer account using **sideloading**.

### Prerequisites

1. **Mac** with Xcode installed
2. **Apple ID** (free account works)
3. **USB cable** to connect iPhone to Mac

### Steps

1. **Clone the repository**
   ```bash
   git clone https://github.com/YOUR_USERNAME/IPhotos-Sync.git
   cd IPhotos-Sync/IPhotos-Sync
   ```

2. **Create your Secrets file**
   ```bash
   cp IPhotos-Sync/Secrets.swift.template IPhotos-Sync/Secrets.swift
   ```
   Edit `Secrets.swift` with your Supabase credentials (see [Configuration](#configuration) below).

3. **Open in Xcode**
   ```bash
   open IPhotos-Sync.xcodeproj
   ```

4. **Configure signing**
   - Select the project in the navigator
   - Go to "Signing & Capabilities" tab
   - Check "Automatically manage signing"
   - Select your **Personal Team** (your Apple ID)
   - Change the **Bundle Identifier** to something unique, e.g.:
     ```
     com.yourname.iphotos-sync
     ```

5. **Connect your iPhone**
   - Connect via USB cable
   - Trust the computer on your iPhone if prompted
   - Select your iPhone as the build target in Xcode

6. **Build and run**
   - Press `Cmd + R` or click the Play button
   - First time: Go to iPhone Settings > General > VPN & Device Management
   - Trust your developer certificate

### How Long Does It Last?

| Account Type | App Validity | Notes |
|--------------|--------------|-------|
| **Free Apple ID** | **7 days** | Must reinstall weekly from Xcode |
| **Paid Developer ($99/year)** | **1 year** | Can also distribute via TestFlight |

With a free account, after 7 days the app will stop opening. Simply:
1. Connect iPhone to Mac
2. Open Xcode
3. Build and run again (`Cmd + R`)

Your data and login will be preserved.

---

## Configuration

Copy the template and fill in your values:

```bash
cp IPhotos-Sync/Secrets.swift.template IPhotos-Sync/Secrets.swift
```

Edit `IPhotos-Sync/Secrets.swift`:

```swift
enum Secrets {
    static let supabaseURL = "https://your-project.supabase.co"
    static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6..."
    static let bucketName = "iphotos"
}
```

### Where to Get These Values

#### Supabase Cloud

1. Go to [supabase.com](https://supabase.com) and create a project
2. Navigate to **Project Settings** > **API**
3. Copy:
   - **Project URL** → `supabaseURL`
   - **anon/public key** → `supabaseAnonKey`

#### Self-Hosted Supabase

1. Your Supabase URL is where you host it, e.g.:
   - `https://supabase.yourdomain.com`
2. Find your anon key in your `.env` file or Supabase Studio:
   - Go to **Settings** > **API**
   - Copy the **anon key**

---

## Supabase Setup

You need to configure storage bucket, database table, and security policies.

### 1. Create Storage Bucket

#### Via Supabase Studio (Web UI)

1. Go to **Storage** in the sidebar
2. Click **New bucket**
3. Name: `iphotos`
4. **Disable** "Public bucket" (keep it private)
5. Click **Create bucket**

#### Via SQL

```sql
INSERT INTO storage.buckets (id, name, public)
VALUES ('iphotos', 'iphotos', false);
```

### 2. Configure Storage Policies

Go to **Storage** > **Policies** > **iphotos bucket**, or run this SQL:

```sql
-- Allow authenticated users to upload to their own folder
CREATE POLICY "Users can upload to own folder"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
    bucket_id = 'iphotos' AND
    (storage.foldername(name))[1] = auth.uid()::text
);

-- Allow authenticated users to read their own files
CREATE POLICY "Users can read own files"
ON storage.objects FOR SELECT
TO authenticated
USING (
    bucket_id = 'iphotos' AND
    (storage.foldername(name))[1] = auth.uid()::text
);

-- Allow authenticated users to update their own files
CREATE POLICY "Users can update own files"
ON storage.objects FOR UPDATE
TO authenticated
USING (
    bucket_id = 'iphotos' AND
    (storage.foldername(name))[1] = auth.uid()::text
);

-- Allow authenticated users to delete their own files
CREATE POLICY "Users can delete own files"
ON storage.objects FOR DELETE
TO authenticated
USING (
    bucket_id = 'iphotos' AND
    (storage.foldername(name))[1] = auth.uid()::text
);
```

### 3. Create Photos Metadata Table

This table stores metadata about uploaded photos for future browsing/organizing.

```sql
-- Create photos metadata table
CREATE TABLE IF NOT EXISTS public.photos (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    filename TEXT NOT NULL,
    original_filename TEXT,
    storage_path TEXT NOT NULL,
    media_type TEXT NOT NULL DEFAULT 'image',
    mime_type TEXT,
    file_size BIGINT,
    width INTEGER,
    height INTEGER,
    duration DOUBLE PRECISION,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    taken_at TIMESTAMPTZ,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    device_model TEXT,

    UNIQUE(user_id, storage_path)
);

-- Create indexes for efficient queries
CREATE INDEX idx_photos_user_id ON public.photos(user_id);
CREATE INDEX idx_photos_taken_at ON public.photos(taken_at);
CREATE INDEX idx_photos_created_at ON public.photos(created_at);
CREATE INDEX idx_photos_media_type ON public.photos(media_type);

-- Enable Row Level Security
ALTER TABLE public.photos ENABLE ROW LEVEL SECURITY;

-- Users can only see their own photos
CREATE POLICY "Users can view own photos"
ON public.photos FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- Users can insert their own photos
CREATE POLICY "Users can insert own photos"
ON public.photos FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id);

-- Users can update their own photos
CREATE POLICY "Users can update own photos"
ON public.photos FOR UPDATE
TO authenticated
USING (auth.uid() = user_id);

-- Users can delete their own photos
CREATE POLICY "Users can delete own photos"
ON public.photos FOR DELETE
TO authenticated
USING (auth.uid() = user_id);
```

### 4. Create a User Account

#### Via Supabase Studio

1. Go to **Authentication** > **Users**
2. Click **Add user** > **Create new user**
3. Enter email and password
4. Click **Create user**

#### Via SQL

```sql
-- Note: This creates an unconfirmed user.
-- Better to use the Studio UI or signup flow.
```

### 5. (Self-Hosted) Configure File Size Limits

For large video uploads, you may need to increase limits.

#### Kong Gateway (docker-compose.yml)

```yaml
kong:
  environment:
    KONG_NGINX_PROXY_PROXY_BUFFER_SIZE: 160k
    KONG_NGINX_PROXY_PROXY_BUFFERS: 64 160k
    KONG_NGINX_PROXY_CLIENT_MAX_BODY_SIZE: 5000m
```

#### Storage API

```yaml
storage:
  environment:
    FILE_SIZE_LIMIT: "5368709120"  # 5GB
    UPLOAD_FILE_SIZE_LIMIT: "5368709120"
```

Restart your Supabase stack after changes:
```bash
docker compose down && docker compose up -d
```

---

## Usage

1. **Open the app** on your iPhone
2. **Sign in** with your Supabase account
3. **Grant photo access** when prompted
4. **Configure sync mode** in Settings:
   - **Auto**: Syncs oldest photos automatically
   - **Manual**: Pick which photos to sync
5. **Tap "Sync Now"**
6. **Approve deletion** when prompted (photos are deleted after successful upload)

---

## File Structure

```
IPhotos-Sync/
├── IPhotos-Sync/
│   ├── Models/
│   │   ├── AppSettings.swift
│   │   └── PhotoAsset.swift
│   ├── Services/
│   │   ├── BackgroundUploadManager.swift
│   │   ├── KeychainManager.swift
│   │   ├── PhotoLibraryService.swift
│   │   ├── PhotoMetadataService.swift
│   │   ├── SupabaseAuthService.swift
│   │   ├── SupabaseStorageService.swift
│   │   ├── SyncManager.swift
│   │   └── TUSUploadManager.swift
│   ├── Views/
│   │   ├── ContentView.swift
│   │   ├── LoginView.swift
│   │   ├── PhotoPickerView.swift
│   │   ├── SettingsView.swift
│   │   └── SyncProgressView.swift
│   ├── Secrets.swift          # Your config (gitignored)
│   └── Secrets.swift.template # Template for others
├── .gitignore
└── README.md
```

---

## Troubleshooting

### "App is no longer available"
Your 7-day signing certificate expired. Reconnect to Xcode and rebuild.

### Upload fails with 401/403
Your session expired. Sign out and sign back in.

### Large videos fail with 502
Your server timeout is too low. See [Configure File Size Limits](#5-self-hosted-configure-file-size-limits).

### Photos not deleting
You denied deletion permission. The app will ask again next sync, or go to Settings > IPhotos Sync and enable full photo access.

---

## License

MIT License - feel free to use and modify.

---

## Contributing

1. Fork the repository
2. Create your feature branch
3. Copy `Secrets.swift.template` to `Secrets.swift` with your test credentials
4. Make your changes
5. Submit a pull request

**Never commit `Secrets.swift`** - it's gitignored for a reason!
