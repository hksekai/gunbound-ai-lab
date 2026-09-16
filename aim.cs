using System;

public static class ArmorBallistics
{
    // Initial Armor coefficients from SanjoSolutions/gunbound-aimbot (Unlicense); live shots must confirm calibration.
    public const double ReferenceGravity = 73.5;
    public const double ReferenceWindScale = 0.74;
    const double Step = 0.05;

    public sealed class ProjectileModel
    {
        public double Gravity { get; set; }
        public double WindScale { get; set; }
        public double SpeedScale { get; set; }
        public double AngleOffsetDegrees { get; set; }
        public double MuzzleForwardRight { get; set; }
        public double MuzzleForwardLeft { get; set; }
        public double MuzzleUp { get; set; }
        public double BodyOffsetY { get; set; }
        public int RadiusPixels { get; set; }
        public double PathMarginPixels { get; set; }
        public double BlastMarginPixels { get; set; }
        public double SelfMarginPixels { get; set; }
        public ProjectileModel()
        {
            Gravity = WindScale = SpeedScale = AngleOffsetDegrees = MuzzleForwardRight = MuzzleForwardLeft =
                MuzzleUp = BodyOffsetY = PathMarginPixels = BlastMarginPixels = SelfMarginPixels = Double.NaN;
            RadiusPixels = -1;
        }
        public void Validate()
        {
            foreach (double value in new[] { Gravity, WindScale, SpeedScale, AngleOffsetDegrees, MuzzleForwardRight,
                MuzzleForwardLeft, MuzzleUp, BodyOffsetY, PathMarginPixels, BlastMarginPixels, SelfMarginPixels })
                if (!Finite(value)) throw new ArgumentException("Every calibrated projectile parameter must be explicit and finite.");
            if (Gravity <= 0 || Gravity > 1000 || WindScale < 0 || WindScale > 10 || SpeedScale <= 0 || SpeedScale > 4 ||
                Math.Abs(AngleOffsetDegrees) > 30 || Math.Abs(MuzzleForwardRight) > 160 || Math.Abs(MuzzleForwardLeft) > 160 ||
                Math.Abs(MuzzleUp) > 160 || Math.Abs(BodyOffsetY) > 160 || RadiusPixels < 0 || RadiusPixels > 16 ||
                PathMarginPixels < 12 || PathMarginPixels > 256 || BlastMarginPixels < 64 || BlastMarginPixels > 512 ||
                SelfMarginPixels < 40 || SelfMarginPixels > 512)
                throw new ArgumentException("Calibrated projectile parameters exceed the supported conservative envelope.");
        }
    }

    public enum EndKind { Unknown, Target, Terrain, OffMap, Timeout, Friendly, OtherEnemy }

    public sealed class NoTrajectoryException : InvalidOperationException
    {
        public NoTrajectoryException() : base("No supported descending trajectory reaches the target height.") { }
    }

    public sealed class Terrain
    {
        public readonly int Width, Height;
        public readonly byte[] Cells;
        public Terrain(int width, int height, byte[] cells)
        {
            if (width < 1 || height < 1 || width > 4096 || height > 4096 ||
                cells == null || cells.Length != checked(width * height))
                throw new ArgumentException("Invalid native terrain dimensions or byte mask.");
            Width = width; Height = height; Cells = cells;
        }
        public bool Solid(int x, int y)
        {
            return x >= 0 && x < Width && y >= 0 && y < Height && Cells[y * Width + x] != 0;
        }
        public bool Touches(int x, int y, int radius)
        {
            if (radius < 0 || radius > 16) throw new ArgumentOutOfRangeException("radius");
            // ponytail: square collision envelope, not a calibrated sprite; a tighter shape needs measured collision data.
            for (int row = Math.Max(0, y - radius); row <= Math.Min(Height - 1, y + radius); row++)
                for (int column = Math.Max(0, x - radius); column <= Math.Min(Width - 1, x + radius); column++)
                    if (Cells[row * Width + column] != 0) return true;
            return false;
        }
        public int Surface(int x, int startY)
        {
            if (x < 0 || x >= Width) return -1;
            for (int y = Math.Max(0, startY); y < Height; y++)
                if (Solid(x, y)) return y;
            return -1;
        }
        public bool Walk(int fromX, int fromY, int toX, int halfWidth, int bodyHeight, out int destinationY)
        {
            destinationY = fromY;
            if (halfWidth < 2 || halfWidth > 64 || bodyHeight < 8 || bodyHeight > 160 ||
                Math.Abs(toX - fromX) > 64 || fromX < halfWidth + 2 || toX < halfWidth + 2 ||
                fromX >= Width - halfWidth - 2 || toX >= Width - halfWidth - 2) return false;
            int ground = Surface(fromX, fromY - bodyHeight / 2);
            if (ground < 0 || Math.Abs(ground - fromY) > bodyHeight / 2) return false;
            int initial = ground, offset = fromY - ground, direction = Math.Sign(toX - fromX);
            for (int x = fromX; ; x += direction)
            {
                int next = Surface(x, ground - 4);
                if (next < 0 || Math.Abs(next - ground) > 4 || Math.Abs(next - initial) > 24) return false;
                int left = Surface(x - halfWidth, next - bodyHeight / 2);
                int right = Surface(x + halfWidth, next - bodyHeight / 2);
                if (left < 0 || right < 0 || Math.Abs(left - next) > halfWidth * 0.7 + 4 ||
                    Math.Abs(right - next) > halfWidth * 0.7 + 4) return false;
                for (int y = next - bodyHeight / 2; y < next - 4; y += 4)
                    if (Solid(x, y) || Solid(x - halfWidth / 2, y) || Solid(x + halfWidth / 2, y)) return false;
                ground = next;
                if (x == toX) { destinationY = ground + offset; return true; }
            }
        }
        public double Slope(int x, int y, int halfWidth, int bodyHeight)
        {
            int left = Surface(x - halfWidth, y - bodyHeight / 2);
            int right = Surface(x + halfWidth, y - bodyHeight / 2);
            if (left < 0 || right < 0) throw new ArgumentException("Ground slope has no verified support.");
            return -Math.Atan2(right - left, halfWidth * 2) * 180 / Math.PI;
        }
    }

    public sealed class Shot
    {
        public int Power { get; private set; }
        public double LandingX { get; private set; }
        public double Error { get; private set; }
        public double LandingY { get; private set; }
        public double FlightSeconds { get; private set; }
        public bool Clear { get; private set; }
        public bool FriendlyBlocked { get; private set; }
        public bool TerrainImpact { get; private set; }
        public EndKind End { get; private set; }
        public int HitSlot { get; private set; }
        public Shot(int power, double landingX, double error, double landingY = 0, double seconds = 0,
            bool clear = false, bool friendlyBlocked = false, bool terrainImpact = false, EndKind end = EndKind.Unknown,
            int hitSlot = -1)
        {
            Power = power;
            LandingX = landingX;
            Error = error; LandingY = landingY; FlightSeconds = seconds; Clear = clear;
            FriendlyBlocked = friendlyBlocked; TerrainImpact = terrainImpact;
            End = end != EndKind.Unknown ? end : terrainImpact ? EndKind.Terrain :
                friendlyBlocked ? EndKind.Friendly : clear ? EndKind.Target : EndKind.Unknown;
            HitSlot = hitSlot;
        }
        public bool UsefulTerrainImpact(double sourceX, double sourceY, double targetX, double targetY)
        {
            if (!TerrainImpact || FriendlyBlocked || !Finite(sourceX) || !Finite(sourceY) ||
                !Finite(targetX) || !Finite(targetY) || !Finite(LandingX) || !Finite(LandingY)) return false;
            double span = Math.Abs(targetX - sourceX);
            double progress = (LandingX - sourceX) * Math.Sign(targetX - sourceX);
            if (span < 1 || progress < 96 || progress > span + 48) return false;
            double distance = Math.Sqrt((LandingX - targetX) * (LandingX - targetX) +
                (LandingY - targetY) * (LandingY - targetY));
            // ponytail: forward near-target terrain or an elevated intervening obstruction only.
            // The 96px clearance and straight-line corridor exclude underfoot/far-floor digging;
            // widening this heuristic needs measured crater/support physics, not a damage prediction.
            return distance <= 96 || (progress <= span &&
                LandingY <= sourceY + (targetY - sourceY) * progress / span + 16 &&
                distance + 32 < Math.Sqrt(span * span + (targetY - sourceY) * (targetY - sourceY)));
        }
    }

    public sealed class Body
    {
        public readonly double X, Y;
        public readonly int Width, Height, NativeSlot;
        public Body(double x, double groundY, int width, int height, int nativeSlot = -1)
        {
            if (!Finite(x) || !Finite(groundY) || width < 4 || width > 128 || height < 8 || height > 160 ||
                nativeSlot < -1 || nativeSlot >= 8)
                throw new ArgumentException("Invalid authoritative native body.");
            X = x; Y = groundY; Width = width; Height = height; NativeSlot = nativeSlot;
        }
        public bool Near(double x, double y, double margin)
        {
            double dx = Math.Max(0, Math.Abs(x - X) - Width / 2.0);
            double dy = Math.Max(0, Math.Abs(y - (Y - Height / 2.0)) - Height / 2.0);
            return dx * dx + dy * dy <= margin * margin;
        }
    }

    static bool FriendlyNear(Body[] friendlies, double x, double y, double margin)
    {
        if (friendlies != null)
            foreach (Body friendly in friendlies)
                if (friendly.Near(x, y, margin)) return true;
        return false;
    }

    public sealed class TerrainChange
    {
        public int RemovedPixels, MinimumX, MaximumX, MinimumY, MaximumY;
        public double CenterX, CenterY, NearestTargetDistance;
    }

    public static TerrainChange CompareTerrain(Terrain before, Terrain after, double targetX, double targetY)
    {
        if (before == null || after == null || before.Width != after.Width || before.Height != after.Height ||
            !Finite(targetX) || !Finite(targetY)) throw new ArgumentException("Incompatible terrain observations.");
        var change = new TerrainChange { MinimumX = before.Width, MinimumY = before.Height,
            MaximumX = -1, MaximumY = -1, NearestTargetDistance = Double.PositiveInfinity };
        double sumX = 0, sumY = 0;
        for (int index = 0; index < before.Cells.Length; index++)
        {
            if (before.Cells[index] == 0 || after.Cells[index] != 0) continue;
            int x = index % before.Width, y = index / before.Width;
            change.RemovedPixels++; sumX += x; sumY += y;
            change.MinimumX = Math.Min(change.MinimumX, x); change.MaximumX = Math.Max(change.MaximumX, x);
            change.MinimumY = Math.Min(change.MinimumY, y); change.MaximumY = Math.Max(change.MaximumY, y);
            change.NearestTargetDistance = Math.Min(change.NearestTargetDistance,
                Math.Sqrt((x - targetX) * (x - targetX) + (y - targetY) * (y - targetY)));
        }
        if (change.RemovedPixels == 0) return null;
        change.CenterX = sumX / change.RemovedPixels; change.CenterY = sumY / change.RemovedPixels;
        return change;
    }

    static bool Finite(double value)
    {
        return !Double.IsNaN(value) && !Double.IsInfinity(value);
    }

    public static Shot Solve(double sourceX, double sourceY, double targetX, double targetY,
        double absoluteAngle, int windDirection, int windPower,
        double gravity = ReferenceGravity, double windScale = ReferenceWindScale, double speedScale = 1)
    {
        if (!Finite(sourceX) || !Finite(sourceY) || !Finite(targetX) || !Finite(targetY) ||
            !Finite(absoluteAngle) || absoluteAngle < -360 || absoluteAngle > 360 ||
            windDirection < 0 || windDirection >= 360 || windPower < 0 || windPower > 40 ||
            !Finite(gravity) || gravity <= 0 || !Finite(windScale) || windScale < 0 ||
            !Finite(speedScale) || speedScale <= 0 || speedScale > 4)
            throw new ArgumentOutOfRangeException("Shot parameters are outside the supported Armor model.");

        double angle = absoluteAngle * Math.PI / 180.0;
        double wind = windDirection * Math.PI / 180.0;
        double ax = Math.Truncate(Math.Cos(wind) * windPower) * windScale;
        double ay = gravity - Math.Truncate(Math.Sin(wind) * windPower) * windScale;
        if (ay <= 0) throw new ArgumentOutOfRangeException("The supported model requires downward net gravity.");
        Shot best = null;

        // ponytail: independent 0.05s Euler projectiles only; splitting/bouncing/delayed children need another verified model.
        for (int power = 1; power <= 400; power++)
        {
            double x = sourceX, y = sourceY;
            double vx = power * speedScale * Math.Cos(angle), vy = -power * speedScale * Math.Sin(angle);
            for (int tick = 0; tick < 400; tick++)
            {
                double previousX = x, previousY = y;
                x += vx * Step;
                y += vy * Step;
                vx += ax * Step;
                vy += ay * Step;
                if (y > previousY && previousY <= targetY && y >= targetY)
                {
                    double fraction = (targetY - previousY) / (y - previousY);
                    double crossingX = previousX + fraction * (x - previousX);
                    double error = Math.Abs(crossingX - targetX);
                    if (best == null || error < best.Error)
                        best = new Shot(power, crossingX, error);
                    break;
                }
            }
        }
        if (best == null)
            throw new NoTrajectoryException();
        return best;
    }

    public static Shot Trace(Terrain terrain, double sourceX, double sourceY, double targetX, double targetY,
        double absoluteAngle, int power, int windDirection, int windPower,
        double gravity = ReferenceGravity, double windScale = ReferenceWindScale, Body[] friendlies = null,
        Body targetBody = null, ProjectileModel model = null, Body[] otherEnemies = null)
    {
        if (model != null) { model.Validate(); gravity = model.Gravity; windScale = model.WindScale; }
        if (terrain == null || power < 1 || power > 400 || !Finite(sourceX) || !Finite(sourceY) ||
            !Finite(targetX) || !Finite(targetY) || !Finite(absoluteAngle) || Math.Abs(absoluteAngle) > 360 ||
            windDirection < 0 || windDirection >= 360 || windPower < 0 || windPower > 40 ||
            !Finite(gravity) || gravity <= 0 || !Finite(windScale) || windScale < 0)
            throw new ArgumentException("Invalid terrain trajectory parameters.");
        if (friendlies != null)
        {
            if (friendlies.Length > 7) throw new ArgumentException("Too many friendly bodies.");
            foreach (Body friendly in friendlies)
                if (friendly == null) throw new ArgumentException("Missing authoritative friendly body.");
        }
        if (otherEnemies != null)
        {
            if (otherEnemies.Length > 6) throw new ArgumentException("Too many non-selected enemy bodies.");
            foreach (Body enemy in otherEnemies)
                if (enemy == null || (targetBody != null && targetBody.NativeSlot >= 0 && enemy.NativeSlot == targetBody.NativeSlot))
                    throw new ArgumentException("Missing or incorrectly selected intercepting enemy body.");
        }
        else if (targetBody != null && targetBody.NativeSlot >= 0)
            throw new ArgumentException("A native target requires an explicit non-selected enemy observation, even when empty.");
        double angle = (absoluteAngle + (model == null ? 0 : model.AngleOffsetDegrees)) * Math.PI / 180;
        double wind = windDirection * Math.PI / 180, speed = power * (model == null ? 1 : model.SpeedScale);
        int radius = model == null ? 2 : model.RadiusPixels;
        double pathMargin = model == null ? 12 : model.PathMarginPixels;
        double blastMargin = model == null ? 64 : model.BlastMarginPixels;
        double ax = Math.Truncate(Math.Cos(wind) * windPower) * windScale;
        double ay = gravity - Math.Truncate(Math.Sin(wind) * windPower) * windScale;
        if (ay <= 0) throw new ArgumentException("The supported model requires downward net gravity.");
        double x = sourceX, y = sourceY, vx = speed * Math.Cos(angle), vy = -speed * Math.Sin(angle);
        for (int tick = 0; tick < 400; tick++)
        {
            double nextX = x + vx * Step, nextY = y + vy * Step;
            int pieces = Math.Max(1, (int)Math.Ceiling(Math.Max(Math.Abs(nextX - x), Math.Abs(nextY - y))));
            for (int piece = 1; piece <= pieces; piece++)
            {
                double fraction = (double)piece / pieces, px = x + (nextX - x) * fraction, py = y + (nextY - y) * fraction;
                double distance = Math.Sqrt((px - targetX) * (px - targetX) + (py - targetY) * (py - targetY));
                double seconds = (tick + fraction) * Step;
                if (FriendlyNear(friendlies, px, py, pathMargin))
                    return new Shot(power, px, distance, py, seconds, false, true);
                bool friendlyImpact = FriendlyNear(friendlies, px, py, blastMargin);
                if (px < 0 || px >= terrain.Width || py >= terrain.Height || py < -4096)
                    return new Shot(power, px, distance, py, seconds, false, friendlyImpact, end: EndKind.OffMap);
                int ix = (int)Math.Round(px), iy = (int)Math.Round(py);
                if (terrain.Touches(ix, iy, radius))
                    return new Shot(power, px, distance, py, seconds, false, friendlyImpact, true);
                // ponytail: sample the first collision across all opposing bodies, not only the aim target.
                // Non-selected bodies win sub-pixel ties conservatively; finer ordering needs swept native hitboxes.
                if (otherEnemies != null)
                    foreach (Body enemy in otherEnemies)
                        if (enemy.Near(px, py, 0))
                            return new Shot(power, px, distance, py, seconds, false, friendlyImpact,
                                end: EndKind.OtherEnemy, hitSlot: enemy.NativeSlot);
                // ponytail: native body-envelope intersection, not sprite/damage truth. Terrain always wins;
                // callers without a native body only get a 2px point crossing, never a 28px through-wall "hit".
                if (targetBody == null ? distance <= 2 : targetBody.Near(px, py, 0))
                    return new Shot(power, px, distance, py, seconds, !friendlyImpact, friendlyImpact,
                        end: EndKind.Target, hitSlot: targetBody == null ? -1 : targetBody.NativeSlot);
            }
            x = nextX; y = nextY; vx += ax * Step; vy += ay * Step;
        }
        return new Shot(power, x, Math.Sqrt((x - targetX) * (x - targetX) + (y - targetY) * (y - targetY)),
            y, 20, end: EndKind.Timeout);
    }

    public static Shot SolveTerrain(Terrain terrain, double sourceX, double sourceY, double targetX, double targetY,
        double absoluteAngle, int windDirection, int windPower, int minimumPower = 40, Body[] friendlies = null,
        Body targetBody = null, ProjectileModel model = null, Action<Shot> observe = null, Body[] otherEnemies = null)
    {
        if (terrain == null) throw new ArgumentNullException("terrain");
        if (minimumPower < 1 || minimumPower > 400) throw new ArgumentOutOfRangeException("minimumPower");
        if (model != null) model.Validate();
        int centerPower;
        try { centerPower = Solve(sourceX, sourceY, targetX, targetY,
            absoluteAngle + (model == null ? 0 : model.AngleOffsetDegrees), windDirection, windPower,
            model == null ? ReferenceGravity : model.Gravity, model == null ? ReferenceWindScale : model.WindScale,
            model == null ? 1 : model.SpeedScale).Power; }
        catch (NoTrajectoryException)
        {
            // Rank possible progress at maximum range; Trace must still prove a viable shot.
            centerPower = 400;
        }
        centerPower = Math.Max(minimumPower, centerPower);
        Shot best = null;
        for (int power = Math.Max(minimumPower, centerPower - 4); power <= Math.Min(400, centerPower + 4); power++)
        {
            Shot shot = Trace(terrain, sourceX, sourceY, targetX, targetY, absoluteAngle, power, windDirection, windPower,
                friendlies: friendlies, targetBody: targetBody, model: model, otherEnemies: otherEnemies);
            if (observe != null) observe(shot);
            if (shot.FriendlyBlocked || (!shot.Clear && !shot.UsefulTerrainImpact(sourceX, sourceY, targetX, targetY))) continue;
            if (best == null || (shot.Clear && !best.Clear) ||
                (shot.Clear == best.Clear && shot.Error < best.Error)) best = shot;
        }
        return best;
    }

    static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    public static string SelfCheck()
    {
        Shot calm = Solve(200, 500, 800, 500, 45, 0, 0);
        double b = Math.Cos(Math.PI / 4) * Step;
        double a = 1.0 / ReferenceGravity;
        double expected = (-b + Math.Sqrt(b * b + 4 * a * 600)) / (2 * a);
        Check(Math.Abs(calm.Power - expected) < 1 && calm.Error < 4,
            "The no-wind result does not match the discrete trajectory equation.");
        Shot mirrored = Solve(800, 500, 200, 500, 135, 0, 0);
        Check(mirrored.Power == calm.Power && Math.Abs(mirrored.Error - calm.Error) < 0.0001,
            "Left/right trajectory symmetry changed.");
        Check(Solve(200, 500, 800, 500, 45, 0, 16).Power < calm.Power,
            "Tailwind must reduce the required power.");
        Check(Solve(200, 500, 800, 500, 45, 180, 16).Power > calm.Power,
            "Headwind must increase the required power.");
        Check(Solve(200, 500, 800, 600, 45, 0, 0).Power < calm.Power,
            "The world-coordinate vertical axis is inverted.");
        bool rejected = false;
        try { Solve(Double.NaN, 0, 100, 0, 45, 0, 0); }
        catch (ArgumentOutOfRangeException) { rejected = true; }
        Check(rejected, "Non-finite observation data was accepted.");
        var cells = new byte[800 * 600];
        for (int y = 500; y < 600; y++)
            for (int x = 0; x < 800; x++) cells[y * 800 + x] = 1;
        var terrain = new Terrain(800, 600, cells);
        var cornerCells = new byte[10 * 10];
        cornerCells[6 * 10 + 6] = 1;
        Check(new Terrain(10, 10, cornerCells).Touches(4, 4, 2), "The conservative collision envelope missed a diagonal terrain cell.");
        int destination;
        Check(terrain.Walk(100, 500, 132, 12, 48, out destination) && destination == 500, "Flat reachable movement was rejected.");
        for (int y = 0; y < 600; y++)
            for (int x = 125; x < 150; x++) cells[y * 800 + x] = 0;
        Check(!terrain.Walk(100, 500, 150, 12, 48, out destination), "A gap or unsupported edge was accepted for movement.");
        for (int y = 0; y < 600; y++) cells[y * 800 + 350] = 1;
        Shot blocked = Trace(terrain, 100, 450, 600, 455, 45, 195, 0, 0);
        Check(!blocked.Clear && blocked.TerrainImpact && blocked.LandingX < 355 &&
            blocked.UsefulTerrainImpact(100, 450, 600, 455), "A useful thin-wall obstruction was lost or tunneled through.");
        Shot excavation = SolveTerrain(terrain, 100, 450, 600, 455, 45, 0, 0);
        Check(excavation != null && !excavation.Clear && excavation.TerrainImpact &&
            excavation.UsefulTerrainImpact(100, 450, 600, 455) && excavation.Power >= 40 && excavation.Power <= 400,
            "A blocked target-directed trajectory did not produce a useful terrain fallback.");
        var nearWall = new[] { new Body(excavation.LandingX + 58, excavation.LandingY + 24, 24, 48) };
        Shot unsafeWall = Trace(terrain, 100, 450, 600, 455, 45, excavation.Power, 0, 0, friendlies: nearWall);
        Check(unsafeWall.TerrainImpact && unsafeWall.FriendlyBlocked &&
            !unsafeWall.UsefulTerrainImpact(100, 450, 600, 455) &&
            SolveTerrain(terrain, 100, 450, 600, 455, 45, 0, 0, friendlies: nearWall) == null,
            "Terrain excavation bypassed the friendly blast margin.");
        for (int y = 0; y < 600; y++) cells[y * 800 + 350] = y >= 500 ? (byte)1 : (byte)0;
        Shot clear = SolveTerrain(terrain, 100, 450, 600, 455, 45, 0, 0);
        Check(clear != null && clear.Clear, "An unobstructed terrain-aware shot was rejected.");
        double middleTime = 250 / (clear.Power * Math.Cos(Math.PI / 4));
        double middleY = 450 - 250 + ReferenceGravity * (middleTime * middleTime - middleTime * Step) / 2;
        Shot friendlyPath = Trace(terrain, 100, 450, 600, 455, 45, clear.Power, 0, 0,
            friendlies: new[] { new Body(350, middleY + 24, 24, 48) });
        Shot friendlyBlast = Trace(terrain, 100, 450, 600, 455, 45, clear.Power, 0, 0,
            friendlies: new[] { new Body(clear.LandingX + 58, clear.LandingY + 24, 24, 48) });
        Check(friendlyPath.FriendlyBlocked && !friendlyPath.Clear && friendlyPath.LandingX < 400 &&
            !friendlyPath.TerrainImpact && !friendlyPath.UsefulTerrainImpact(100, 450, 600, 455) &&
            friendlyBlast.FriendlyBlocked && !friendlyBlast.Clear,
            "A teammate on the trajectory or inside the conservative impact margin was accepted.");
        Check(Trace(terrain, 100, 450, 600, 455, 45, clear.Power, 0, 0,
            friendlies: new[] { new Body(40, 500, 24, 48) }).Clear,
            "A safe, distant teammate changed the existing shot.");
        Check(Solve(100, 100, 300, 300, -10, 0, 0).Error < 5, "A valid downward shot was rejected.");
        var air = new Terrain(800, 600, new byte[800 * 600]);
        Shot offMap = Trace(air, 100, 450, 600, 455, 0, 400, 0, 0);
        Shot timeout = Trace(air, 100, 450, 600, 455, 90, 40, 0, 0, gravity: 0.01);
        Check(offMap.LandingX >= 800 && offMap.End == EndKind.OffMap && !offMap.Clear && !offMap.TerrainImpact &&
            !offMap.UsefulTerrainImpact(100, 450, 600, 455) &&
            timeout.FlightSeconds == 20 && timeout.End == EndKind.Timeout && !timeout.Clear && !timeout.TerrainImpact &&
            !timeout.UsefulTerrainImpact(100, 450, 600, 455),
            "Leaving the map or timing out was classified as useful terrain collision.");
        Shot nearTarget = Trace(terrain, 100, 450, 600, 455, 45, 178, 0, 0);
        Shot farFloor = Trace(terrain, 100, 450, 600, 455, 45, 80, 0, 0);
        Shot underfoot = Trace(terrain, 100, 450, 600, 455, -90, 40, 0, 0);
        Shot away = Trace(terrain, 400, 450, 700, 455, 135, 80, 0, 0);
        Check(!nearTarget.Clear && nearTarget.UsefulTerrainImpact(100, 450, 600, 455) &&
            farFloor.TerrainImpact && !farFloor.UsefulTerrainImpact(100, 450, 600, 455) &&
            underfoot.TerrainImpact && !underfoot.UsefulTerrainImpact(100, 450, 600, 455) &&
            away.TerrainImpact && !away.UsefulTerrainImpact(400, 450, 700, 455),
            "Near-target digging was rejected, or arbitrary/underfoot/away terrain was accepted.");
        byte[] changed = (byte[])cells.Clone();
        changed[520 * 800 + 200] = changed[520 * 800 + 201] = 0;
        TerrainChange footprint = CompareTerrain(terrain, new Terrain(800, 600, changed), 200, 500);
        Check(footprint != null && footprint.RemovedPixels == 2 && footprint.CenterX == 200.5 &&
            footprint.CenterY == 520 && footprint.NearestTargetDistance == 20 &&
            CompareTerrain(terrain, terrain, 200, 500) == null, "Measured terrain-change feedback changed.");
        return "PASS: trajectory symmetry/wind/elevation, useful terrain/thin-wall fallback, off-map/timeout/underfoot rejection, friendly trajectory/blast margins, and supported movement without gaps. Live-client calibration is separate.";
    }
}
