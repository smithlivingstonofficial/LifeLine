-- Enable PostGIS for location calculations
CREATE EXTENSION IF NOT EXISTS postgis;

-- 1. Define Status Enums to keep data consistent
CREATE TYPE alert_type AS ENUM ('accident', 'medical', 'fire', 'crime', 'other');
CREATE TYPE cluster_status AS ENUM ('pending', 'accepted', 'resolved', 'false_alarm');

-- NEW SECTION: Define a role enum for our users
CREATE TYPE app_role AS ENUM ('user', 'hospital', 'admin');

-- NEW SECTION: Create the "profiles" table
-- This table stores public user data and is linked to auth.users
CREATE TABLE profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    full_name TEXT,
    phone TEXT,
    role app_role DEFAULT 'user',
    location GEOGRAPHY(POINT), -- Crucial for hospitals
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 2. Create the "Cluster" Table (Group of accidents)
CREATE TABLE accident_clusters (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    location GEOGRAPHY(POINT) NOT NULL,
    status cluster_status DEFAULT 'pending',
    accepted_by_hospital_id UUID REFERENCES profiles(id), -- Changed to reference profiles
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_activity_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    alert_count INT DEFAULT 1
);

-- 3. Create the "Individual Alerts" Table (Raw user inputs)
CREATE TABLE emergency_alerts (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES profiles(id) DEFAULT auth.uid(), -- Changed to reference profiles
    cluster_id UUID REFERENCES accident_clusters(id),
    location GEOGRAPHY(POINT) NOT NULL,
    alert_type alert_type DEFAULT 'accident',
    image_url TEXT,
    is_witness BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 4. Create Spatial Indexes (CRITICAL for performance)
CREATE INDEX idx_profiles_location ON profiles USING GIST (location); -- New index
CREATE INDEX idx_clusters_location ON accident_clusters USING GIST (location);
CREATE INDEX idx_alerts_location ON emergency_alerts USING GIST (location);
CREATE INDEX idx_clusters_status ON accident_clusters (status);

-- NEW SECTION: Automation to create a profile for each new user
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, phone, role)
  VALUES (new.id, new.phone, 'user');
  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();


-- 5. The Clustering Logic Function (Unchanged)
CREATE OR REPLACE FUNCTION process_emergency_clustering()
RETURNS TRIGGER AS $$
DECLARE
    found_cluster_id UUID;
BEGIN
    SELECT id INTO found_cluster_id
    FROM accident_clusters
    WHERE status IN ('pending', 'accepted')
    AND ST_DWithin(location, NEW.location, 200)
    AND last_activity_at > NOW() - INTERVAL '20 minutes'
    ORDER BY location <-> NEW.location
    LIMIT 1;

    IF found_cluster_id IS NOT NULL THEN
        NEW.cluster_id := found_cluster_id;
        UPDATE accident_clusters
        SET 
            last_activity_at = NOW(),
            alert_count = alert_count + 1
        WHERE id = found_cluster_id;
    ELSE
        INSERT INTO accident_clusters (location, last_activity_at)
        VALUES (NEW.location, NOW())
        RETURNING id INTO found_cluster_id;
        NEW.cluster_id := found_cluster_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Attach the clustering trigger (Unchanged)
CREATE TRIGGER trigger_auto_cluster_alert
BEFORE INSERT ON emergency_alerts
FOR EACH ROW
EXECUTE FUNCTION process_emergency_clustering();


-- 6. Row Level Security (RLS) Setup
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE accident_clusters ENABLE ROW LEVEL SECURITY;
ALTER TABLE emergency_alerts ENABLE ROW LEVEL SECURITY;

-- Allow users to see and edit their own profile
CREATE POLICY "Users can manage their own profile" ON profiles
    FOR ALL USING (auth.uid() = id);

-- USERS: Can only see their own alerts
CREATE POLICY "Users can view their own alerts" ON emergency_alerts
    FOR SELECT USING (auth.uid() = user_id);
-- USERS: Can only create alerts for themselves
CREATE POLICY "Users can create alerts" ON emergency_alerts
    FOR INSERT WITH CHECK (auth.uid() = user_id);

-- HOSPITALS: Can see clusters within 15KM radius (This will now work)
CREATE POLICY "Hospitals can view nearby clusters" ON accident_clusters
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM profiles
            WHERE id = auth.uid()
            AND role = 'hospital'
            AND ST_DWithin(profiles.location, accident_clusters.location, 15000) -- 15 KM
        )
    );

-- Allow everyone to read profiles (e.g. to get a hospital name)
CREATE POLICY "Public profiles are viewable by everyone." ON profiles
    FOR SELECT USING (true);