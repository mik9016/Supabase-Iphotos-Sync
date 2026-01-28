-- Photos metadata table
CREATE TABLE IF NOT EXISTS photos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    filename TEXT NOT NULL,
    storage_path TEXT NOT NULL,

    -- Date/time for grouping
    taken_at TIMESTAMPTZ,
    year INT,
    month INT,
    day INT,

    -- Location for "by place" grouping
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,

    -- File info
    media_type TEXT NOT NULL,  -- 'image' or 'video'
    mime_type TEXT,
    file_size BIGINT,
    width INT,
    height INT,
    duration DOUBLE PRECISION,  -- for videos (seconds)

    -- Device info
    device_id TEXT,  -- PHAsset localIdentifier

    -- Timestamps
    uploaded_at TIMESTAMPTZ DEFAULT now(),

    -- Constraints
    UNIQUE(user_id, device_id)
);

-- Indexes for efficient querying
CREATE INDEX IF NOT EXISTS idx_photos_user_id ON photos(user_id);
CREATE INDEX IF NOT EXISTS idx_photos_taken_at ON photos(taken_at);
CREATE INDEX IF NOT EXISTS idx_photos_year_month ON photos(user_id, year, month);
CREATE INDEX IF NOT EXISTS idx_photos_location ON photos(latitude, longitude) WHERE latitude IS NOT NULL;

-- Row Level Security
ALTER TABLE photos ENABLE ROW LEVEL SECURITY;

-- Users can only see their own photos
CREATE POLICY "Users can view own photos"
ON photos FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- Users can insert their own photos
CREATE POLICY "Users can insert own photos"
ON photos FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id);

-- Users can update their own photos
CREATE POLICY "Users can update own photos"
ON photos FOR UPDATE
TO authenticated
USING (auth.uid() = user_id);

-- Users can delete their own photos
CREATE POLICY "Users can delete own photos"
ON photos FOR DELETE
TO authenticated
USING (auth.uid() = user_id);
