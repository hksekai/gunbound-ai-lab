using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

public static class BotController
{
    static volatile bool stopping;
    static string stopReason;
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static StreamWriter log;
    static string lastStatus = "";
    static Difficulty activeDifficulty;
    static readonly Random AimRandom = new Random();
    static readonly System.Collections.Generic.Queue<double> RecentPositions = new System.Collections.Generic.Queue<double>();
    static PendingImpact pendingImpact;
    static double missedAngle, missedX, missedTargetX, missedTargetY;
    static int repeatedMisses;
    static State excavationTarget;
    static int failedExcavations;
    static double movementSpent;
    static State targetLock, matchContext;
    static TurnNoise turnNoise;
    static MoveGoal moveGoal;
    static readonly List<ShotMemory> GoodShots = new List<ShotMemory>();
    static int chargeUncertainty = 4;
    static Shot2Calibration shot2 = new Shot2Calibration { Status = "deferred", MinimumModelConfidencePercent = 80 };
    static bool showModelConfidence = true;
    const string ConfidenceMeaning = "model-robustness estimate; NOT calibrated real-world hit probability";
    static string botAccount;
    static int inputOwnerThread;
    static string inputFaultFile;
    static bool inputFaultObserved;
    const string GuestInputMutex = @"Local\GunBoundAILab.GuestInput";
    static readonly string[] DuelNames = { "Player", "BotOne" };
    static readonly string[] TeamNames = { "Player", "BotOne", "BotTwo", "BotThree" };
    static string BotName { get { return botAccount ?? "Bot"; } }
    delegate bool ConsoleHandler(uint kind);
    static readonly ConsoleHandler ExitHandler = OnConsoleExit;
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleCtrlHandler(ConsoleHandler handler, bool add);
    [DllImport("user32.dll")]
    static extern short GetAsyncKeyState(int key);

    sealed class SnapshotBusyException : Exception
    {
        public SnapshotBusyException() : base("Native state is changing.") { }
        public SnapshotBusyException(string message) : base(message) { }
    }
    enum RoomInput { None, Unready, SwitchTeam, Ready, Start }
    enum TurnAction { None, Shot, Repositioned }

    sealed class TurnTracker
    {
        bool seen, allowInitial;
        uint battle;
        int number, actor;
        public bool CanAct { get; private set; }
        public void Reset(bool initial) { seen = false; allowInitial = initial; CanAct = false; }
        public bool Observe(uint currentBattle, int currentNumber, int currentActor)
        {
            if (!Pointer(currentBattle) || currentNumber < 0 || currentNumber > UInt16.MaxValue ||
                currentActor < 0 || currentActor >= 8) throw new InvalidDataException("Invalid native turn identity.");
            if (!seen || currentBattle != battle)
            {
                CanAct = !seen && allowInitial;
                seen = true; battle = currentBattle; number = currentNumber; actor = currentActor;
                return true;
            }
            int advance = (currentNumber - number) & 0xFFFF;
            if (advance >= 0x8000 || (advance == 0 && currentActor != actor))
                throw new SnapshotBusyException("Waiting for a current, fully published UDP_TURN.");
            if (advance == 0) return false;
            number = currentNumber; actor = currentActor; CanAct = true;
            return true;
        }
    }

    sealed class RoomState
    {
        public uint Game, Options;
        public int Mode, RoomId, Capacity, GameType, SelfSlot, MasterSlot, PlayerSlot = -1, Occupied;
        public byte[] States = new byte[8], Teams = new byte[8];
        public string[] Names = new string[8];
        public bool ReadyRequested, StartBlocked, InputBlocked;
        public string SelfName { get { return Names[SelfSlot]; } }
        public bool Duel { get { return Capacity == 2 && RosterIssue(this, true, true) == null; } }
        public string Key
        {
            get
            {
                return Game + ":" + Mode + ":" + RoomId + ":" + Capacity + ":" + Options + ":" +
                    SelfSlot + ":" + MasterSlot + ":" +
                    String.Join("|", Names) + ":" + Convert.ToBase64String(States) + ":" +
                    Convert.ToBase64String(Teams) + ":" + ReadyRequested + ":" + StartBlocked + ":" + InputBlocked;
            }
        }
    }

    sealed class RoomRequest
    {
        public RoomState Before;
        public RoomInput Action;
        public readonly Stopwatch Watch = Stopwatch.StartNew();
        public bool Pending(RoomState room)
        {
            if (room.Game != Before.Game || room.RoomId != Before.RoomId ||
                room.SelfSlot != Before.SelfSlot || room.SelfName != Before.SelfName) return false;
            if (Action == RoomInput.SwitchTeam) return room.Teams[room.SelfSlot] == Before.Teams[Before.SelfSlot];
            if (Action == RoomInput.Unready) return room.States[room.SelfSlot] != 1 || room.ReadyRequested;
            if (Action == RoomInput.Ready) return room.States[room.SelfSlot] != 3 || !room.ReadyRequested;
            return room.Mode == 9;
        }
    }

    public sealed class DifficultyDocument
    {
        public int SchemaVersion { get; set; }
        public System.Collections.Generic.Dictionary<string, string> Assignments { get; set; }
        public System.Collections.Generic.Dictionary<string, Difficulty> Tiers { get; set; }
        public Shot2Calibration ArmorShot2 { get; set; }
        public bool ShowModelConfidence { get; set; }
    }

    public sealed class Shot2Calibration
    {
        public string Status { get; set; }
        public int MinimumModelConfidencePercent { get; set; }
        public string Model { get; set; }
        public string Evidence { get; set; }
        public int? SelectionKey { get; set; }
        public bool NativeSelectionVerified { get; set; }
        public ArmorBallistics.ProjectileModel[] Projectiles { get; set; }
        public int? MaximumWindPower { get; set; }
        public int[] AllowedFacings { get; set; }
        public int? MaximumAbsoluteSlopeDegrees { get; set; }
        public int? MinimumGunAngle { get; set; }
        public int? MaximumGunAngle { get; set; }
        public int? MinimumPower { get; set; }
        public int? MaximumPower { get; set; }
        public int? MinimumDistancePixels { get; set; }
        public int? MaximumDistancePixels { get; set; }
        // ponytail: the exact client's ODoubleBullet continues after impact; independent first-impact traces are insufficient.
        // JSON cannot enable S2 in this build. A validated native launch/continuation/per-impact safety model must replace this gate.
        public bool Available { get { return false; } }
        public string DisabledReason
        {
            get { return "Automatic Armor S2 disabled: runtime calibration deferred by the user. ODoubleBullet continues after the first impact and uses distinct native muzzle/launch fields and angle limits; no validated continuation/per-impact safety model is available."; }
        }
        public void Validate()
        {
            if (MinimumModelConfidencePercent != 80)
                throw new InvalidDataException("The user-approved eventual S2 policy requires the 80% model-confidence DIRECT threshold.");
            if (Status != "pending" && Status != "deferred") throw new InvalidDataException(DisabledReason);
            if (Projectiles != null || NativeSelectionVerified || SelectionKey.HasValue || Model != null || Evidence != null ||
                MaximumWindPower.HasValue || AllowedFacings != null || MaximumAbsoluteSlopeDegrees.HasValue ||
                MinimumGunAngle.HasValue || MaximumGunAngle.HasValue || MinimumPower.HasValue || MaximumPower.HasValue ||
                MinimumDistancePixels.HasValue || MaximumDistancePixels.HasValue)
                throw new InvalidDataException(DisabledReason + " Reserved calibration fields must remain unset.");
        }
    }

    public sealed class Difficulty
    {
        public Behavior Behavior { get; set; }
        public Gear Gear { get; set; }
        public string Name { get; set; }
    }

    public sealed class Behavior
    {
        public string Mobile { get; set; }
        public int Shot { get; set; }
        public int ThinkDelayMs { get; set; }
        public double AimErrorDegrees { get; set; }
        public int MaxAngleAdjustmentMs { get; set; }
        public int TargetEstimateErrorPixels { get; set; }
        public int AngleStepDegrees { get; set; }
        public int MaxMovePixels { get; set; }
        public int PowerErrorUnits { get; set; }
    }

    public sealed class Gear
    {
        public string Name { get; set; }
    }

    static DifficultyDocument Profiles(string account)
    {
        var profiles = Json.Deserialize<DifficultyDocument>(
            File.ReadAllText(Path.Combine(LabClient.Root, "profiles", "difficulty.json")));
        if (profiles == null || profiles.SchemaVersion != 1 || profiles.Assignments == null ||
            profiles.Tiers == null || profiles.Tiers.Count != 3 || !profiles.Assignments.ContainsKey(account) ||
            profiles.ArmorShot2 == null)
            throw new InvalidDataException("Invalid difficulty configuration.");
        profiles.ArmorShot2.Validate();
        foreach (string name in new[] { "easy", "medium", "hard" })
        {
            Difficulty tier;
            if (!profiles.Tiers.TryGetValue(name, out tier) || tier == null || tier.Behavior == null ||
                tier.Gear == null || String.IsNullOrWhiteSpace(tier.Gear.Name))
                throw new InvalidDataException("Incomplete difficulty preset: " + name);
            Behavior behavior = tier.Behavior;
            if (behavior.Mobile != "Armor" || behavior.Shot != 1 || behavior.ThinkDelayMs < 0 ||
                behavior.ThinkDelayMs > 5000 || behavior.MaxAngleAdjustmentMs < 0 ||
                behavior.MaxAngleAdjustmentMs > 5000 || Double.IsNaN(behavior.AimErrorDegrees) ||
                Double.IsInfinity(behavior.AimErrorDegrees) || behavior.AimErrorDegrees < 0 ||
                behavior.AimErrorDegrees > 5 || behavior.TargetEstimateErrorPixels < 0 ||
                behavior.TargetEstimateErrorPixels > 30 || behavior.AngleStepDegrees < 1 ||
                behavior.AngleStepDegrees > 10 || behavior.MaxMovePixels < 0 || behavior.MaxMovePixels > 48 ||
                behavior.PowerErrorUnits < 0 || behavior.PowerErrorUnits > 12)
                throw new InvalidDataException("Unsupported difficulty behavior: " + name);
            tier.Name = name;
        }
        foreach (var assignment in profiles.Assignments)
            if (!TeamNames.Skip(1).Contains(assignment.Key) || !profiles.Tiers.ContainsKey(assignment.Value))
                throw new InvalidDataException("Unsupported bot difficulty assignment: " + assignment.Key + ".");
        return profiles;
    }

    static double AimError(Difficulty difficulty, Random random)
    {
        return (random.NextDouble() * 2 - 1) * difficulty.Behavior.AimErrorDegrees;
    }

    sealed class State
    {
        public int Mode, Slot, TargetSlot = -1, ActiveSlot, TurnNumber, Mobile, Angle, Facing, Slope, Wind, WindDirection;
        public uint Game, Battle, Unit, Active, Charge;
        public bool Turn, SelfAlive;
        public RoomState Room;
        public UnitState[] Units = new UnitState[8];
        public string TargetName;
        public double X, Y, TargetX, TargetY;
        public bool MyTurn { get { return Mode == 11 && SelfAlive && Unit == Active && Turn && Slot == ActiveSlot; } }
        public State Copy() { return (State)MemberwiseClone(); }
    }

    sealed class UnitState
    {
        public uint Pointer;
        public int Slot, Team, Health, MaximumHealth, Width, Height;
        public string Name;
        public bool Alive;
        public double X, Y;
        public UnitState Copy() { return (UnitState)MemberwiseClone(); }
        public string Key
        {
            get { return Pointer + ":" + Slot + ":" + Name + ":" + Team + ":" + Health + ":" + MaximumHealth + ":" +
                Alive + ":" + X + ":" + Y + ":" + Width + ":" + Height; }
        }
    }

    sealed class AimState
    {
        public int GunAngle, WorldAngle, Minimum, Maximum, Minimum1, Maximum1, Minimum2, Maximum2;
        public int MoveRemaining, MoveMaximum, Width, Height, ShotMode;
        public bool Legal(int angle)
        {
            return angle >= Minimum && angle <= Maximum;
        }
        public bool Bonus(int angle)
        {
            return (angle >= Minimum1 && angle <= Maximum1) || (angle >= Minimum2 && angle <= Maximum2);
        }
    }

    sealed class ShotPlan
    {
        public int GunAngle, TargetSlot = -1, Facing, Weapon = 1;
        public double X, Y, Slope, Score, GoalX, GoalY;
        public ArmorBallistics.Shot Shot;
        public Robustness Confidence;
        public bool Learned;
        public bool MoveOnly { get { return Shot == null; } }
    }

    sealed class Robustness
    {
        public int Samples, SafeSamples, DirectSamples;
        public ArmorBallistics.Shot Nominal;
        public bool NominalDirect;
        public double Percent { get { return Samples == 0 ? 0 : 100.0 * DirectSamples / Samples; } }
        public string Meaning { get { return ConfidenceMeaning; } }
        public bool Safe { get { return Samples > 0 && Samples == SafeSamples; } }
    }

    sealed class SearchStats
    {
        public int TargetSlot, Angles, MovedAngles, PowerTraces, TerrainStops, FriendlyStops, OtherEnemyStops, OffMap, Timeouts;
        public double TargetEstimateX, TargetEstimateY;
        public int NoUsablePower, SelfRisk, UnsafeVariations, ExhaustedDigging, UselessTerrain, UnsupportedMoves, BodyBlockedMoves, FacingUnavailable, OutsideShot2Envelope;
        public void Observe(ArmorBallistics.Shot shot)
        {
            PowerTraces++;
            if (shot.FriendlyBlocked) FriendlyStops++;
            if (shot.TerrainImpact) TerrainStops++;
            if (shot.End == ArmorBallistics.EndKind.OtherEnemy) OtherEnemyStops++;
            if (shot.End == ArmorBallistics.EndKind.OffMap) OffMap++;
            if (shot.End == ArmorBallistics.EndKind.Timeout) Timeouts++;
        }
    }

    sealed class ShotMemory
    {
        public State Context;
        public string TerrainKey, WeaponKey;
        public int Weapon, GunAngle, Power;
    }

    sealed class MoveGoal
    {
        public State Context;
        public string TerrainKey;
        public double X, Y;
        public int NoProgress;
    }

    sealed class TurnNoise
    {
        public State Turn;
        public double Angle, EstimateX, EstimateY;
        public int Power;
    }

    sealed class PendingImpact
    {
        public State Turn;
        public ArmorBallistics.Terrain Before;
        public ArmorBallistics.Shot Shot;
        public double WorldAngle;
        public int GunAngle, ObservedPower, Weapon = 1;
        public bool DirectAttempt, MemoryRecorded, FeedbackRecorded;
        public long NextSample;
        public readonly Stopwatch Watch = Stopwatch.StartNew();
        public bool Excavation { get { return !DirectAttempt && Shot != null && !Shot.Clear; } }
    }

    static bool OtherTurn(State state)
    {
        return state.Mode == 11 && state.ActiveSlot != state.Slot && state.Active != state.Unit;
    }

    static bool SameActorTurn(State first, State second)
    {
        return first.Mode == 11 && second.Mode == 11 && first.Battle == second.Battle &&
            first.Game == second.Game && first.Unit == second.Unit && first.Slot == second.Slot &&
            first.TurnNumber == second.TurnNumber && first.ActiveSlot == second.ActiveSlot;
    }

    static bool SameTurn(State first, State second)
    {
        return SameActorTurn(first, second) && ((first.Room == null && second.Room == null) ||
             (first.Room != null && second.Room != null && first.Room.Key == second.Room.Key));
    }

    static uint Address(uint start, uint offset) { return checked(start + offset); }
    static bool Pointer(uint value) { return value >= 0x10000 && value < 0x7FFF0000; }

    static int ResolveTargetSlot(RoomState room, UnitState[] units, int activeSlot)
    {
        string issue = RosterIssue(room, true, true);
        if (issue != null) throw new InvalidDataException(issue);
        if (units == null || units.Length != 8 || activeSlot < 0 || activeSlot >= 8 ||
            room.States[activeSlot] == 0 || units[activeSlot] == null)
            throw new InvalidDataException("The native actor is not a verified participant.");
        for (int slot = 0; slot < 8; slot++)
            if ((room.States[slot] != 0) != (units[slot] != null) ||
                (units[slot] != null && units[slot].Slot != slot))
                throw new InvalidDataException("The native units do not match the complete named roster.");
        UnitState self = units[room.SelfSlot];
        if (!self.Alive) return -1;
        return Enumerable.Range(0, 8).Where(slot => units[slot] != null && units[slot].Alive &&
            room.Teams[slot] != room.Teams[room.SelfSlot])
            .OrderBy(slot => Math.Abs(units[slot].X - self.X)).ThenBy(slot => slot)
            .DefaultIfEmpty(-1).First();
    }

    static bool Enemy(State state, int slot)
    {
        return slot >= 0 && slot < 8 && state.Room != null && state.Room.States[slot] != 0 &&
            state.Units[slot] != null && state.Units[slot].Alive &&
            state.Room.Teams[slot] != state.Room.Teams[state.Slot];
    }

    static State ForTarget(State state, int slot)
    {
        if (!Enemy(state, slot)) throw new LabClient.ChargeUnavailableException("The chosen target is no longer a living native enemy.");
        State result = state.Copy();
        result.TargetSlot = slot; result.TargetName = state.Room.Names[slot];
        result.TargetX = state.Units[slot].X; result.TargetY = state.Units[slot].Y - state.Units[slot].Height / 2.0;
        return result;
    }

    static int ObservedTarget(State state)
    {
        int nearest = ResolveTargetSlot(state.Room, state.Units, state.ActiveSlot);
        if (nearest < 0 || targetLock == null || !SameTurn(state, targetLock)) return nearest;
        int slot = targetLock.TargetSlot;
        return Enemy(state, slot) && state.Units[slot].Pointer == targetLock.Units[slot].Pointer ? slot : -1;
    }

    static State LockTarget(State state, int slot)
    {
        CheckTurn(state);
        State chosen = ForTarget(state, slot);
        if (moveGoal != null && moveGoal.Context.TargetSlot != slot) moveGoal = null;
        targetLock = chosen;
        Event("target-lock", new { battle = chosen.Battle, turn = chosen.TurnNumber, self = chosen.Slot,
            targetSlot = slot, targetName = chosen.TargetName, targetUnit = chosen.Units[slot].Pointer });
        return chosen;
    }

    static void ResetTactics(State state)
    {
        matchContext = state; targetLock = null; turnNoise = null; moveGoal = null;
        GoodShots.Clear(); RecentPositions.Clear(); chargeUncertainty = 4;
        repeatedMisses = 0; excavationTarget = null; failedExcavations = 0;
    }

    static void EnsureMatch(State state)
    {
        if (matchContext == null || matchContext.Battle != state.Battle || matchContext.Game != state.Game ||
            matchContext.Unit != state.Unit || matchContext.Slot != state.Slot)
            ResetTactics(state);
        else if (matchContext.Room.Key != state.Room.Key)
        {
            GoodShots.Clear(); moveGoal = null; targetLock = null; matchContext = state;
        }
    }

    static TurnNoise NoiseFor(State state, Difficulty difficulty, Random random)
    {
        if (turnNoise == null || !SameActorTurn(turnNoise.Turn, state))
            turnNoise = new TurnNoise { Turn = state, Angle = AimError(difficulty, random),
                Power = random.Next(-difficulty.Behavior.PowerErrorUnits, difficulty.Behavior.PowerErrorUnits + 1),
                EstimateX = (random.NextDouble() * 2 - 1) * difficulty.Behavior.TargetEstimateErrorPixels,
                EstimateY = (random.NextDouble() * 2 - 1) * difficulty.Behavior.TargetEstimateErrorPixels };
        return turnNoise;
    }

    static uint Decode(LabClient.MemoryReader memory, uint field, uint data, uint keys)
    {
        uint index = memory.UInt32(Address(field, 4));
        if (index >= 0x100000) throw new InvalidDataException("The client wrapper index is outside the supported profile.");
        uint keyAddress = Address(keys, checked(4 * (index >> 3)));
        uint before = memory.UInt32(keyAddress);
        uint word = memory.UInt32(Address(data, checked(4 * index)));
        if (before != memory.UInt32(keyAddress) || index != memory.UInt32(Address(field, 4)))
            throw new SnapshotBusyException();
        return word ^ before;
    }

    static int DesiredTeam(RoomState room, string name)
    {
        return name == "Player" || name == "BotTwo" ? room.Teams[room.PlayerSlot] : 1 - room.Teams[room.PlayerSlot];
    }

    static string RosterIssue(RoomState room, bool complete, bool balanced)
    {
        if (room.Capacity != 2 && room.Capacity != 4)
            return "Unsupported native room capacity " + room.Capacity + "; only 2 and 4 are supported.";
        if (room.GameType != 0)
            return "Unsupported native game type " + room.GameType + "; choose Solo (0), not Score/Tag/Jewel.";
        string[] expected = room.Capacity == 2 ? DuelNames : TeamNames;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        for (int slot = 0; slot < 8; slot++)
        {
            if (room.States[slot] == 0) continue;
            string name = room.Names[slot];
            if (!expected.Contains(name)) return "Unapproved account in native slot " + slot + ": " + name + ".";
            if (!seen.Add(name)) return "Duplicate native account identity: " + name + ".";
            if (room.Teams[slot] > 1) return "Unknown native team for " + name + ": " + room.Teams[slot] + ".";
        }
        if (room.States[room.MasterSlot] == 0) return "Waiting for an occupied native master slot.";
        if (complete && seen.Count != expected.Length)
            return "Incomplete " + room.Capacity + "-slot roster; waiting for " +
                String.Join(", ", expected.Where(name => !seen.Contains(name))) + ".";
        if (balanced)
        {
            if (room.PlayerSlot < 0) return "Waiting for the verified Player team.";
            // Pairing is a room-setup policy; combat follows the actual balanced native teams.
            for (int slot = 0; slot < 8; slot++)
                if (room.Mode != 11 && room.States[slot] != 0 && room.Teams[slot] != DesiredTeam(room, room.Names[slot]))
                    return "Waiting for assigned teams: Player/BotTwo versus BotOne/BotThree (BotOne opposes Player in 1v1).";
            if (Enumerable.Range(0, 8).Count(slot => room.States[slot] != 0 && room.Teams[slot] == 0) != room.Capacity / 2 ||
                Enumerable.Range(0, 8).Count(slot => room.States[slot] != 0 && room.Teams[slot] == 1) != room.Capacity / 2)
                return "Waiting for complete balanced native teams.";
        }
        return null;
    }

    static RoomState ParseRoom(int self, int master, int capacity, uint options, byte[] roster)
    {
        if (self < 0 || self >= 8 || master < 0 || master >= 8 || roster == null || roster.Length != 0x1E5)
            throw new InvalidDataException("Invalid native room roster layout.");
        var room = new RoomState { Mode = 9, SelfSlot = self, MasterSlot = master,
            Capacity = capacity, Options = options, GameType = (int)((options >> 18) & 3) };
        for (int slot = 0; slot < 8; slot++)
        {
            byte state = roster[0x1DD + slot], team = roster[0x1D5 + slot];
            if (state > 4 || (state != 0 && team > 1 && team != 255))
                throw new InvalidDataException("Unsupported native room slot " + slot + ": occupancy=" + state + ", team=" + team + ".");
            room.States[slot] = state;
            room.Teams[slot] = team;
            if (state == 0) continue;
            int start = slot * 20, end = Array.IndexOf(roster, (byte)0, start, 13);
            if (end <= start)
                throw new InvalidDataException("An occupied room slot has no bounded native account name.");
            for (int i = start; i < end; i++)
                if (roster[i] < 33 || roster[i] > 126)
                    throw new InvalidDataException("Unsupported native room account-name encoding.");
            room.Names[slot] = Encoding.ASCII.GetString(roster, start, end - start);
            room.Occupied++;
            if (room.Names[slot] == "Player") room.PlayerSlot = slot;
        }
        if (room.States[self] == 0) throw new SnapshotBusyException();
        return room;
    }

    static RoomState ReadRoom(LabClient.MemoryReader memory, int mode)
    {
        if ((mode != 9 && mode != 11) || memory.Int32(0x0087053C) != mode ||
            memory.Byte(0x008F4A2C) != 0) throw new SnapshotBusyException();
        uint game = memory.UInt32(0x008701CC);
        uint data = memory.UInt32(0x008F4A1C), keys = memory.UInt32(0x008F4A24);
        if (!Pointer(game) || !Pointer(data) || !Pointer(keys)) throw new SnapshotBusyException();
        uint self = Decode(memory, Address(game, 0x1A634), data, keys);
        uint master = Decode(memory, Address(game, 0x1A640), data, keys);
        if (self >= 8 || master >= 8) throw new SnapshotBusyException();
        byte[] roster = memory.Read(Address(game, 0x24165), 0x1E5);
        int roomId = memory.UInt16(Address(game, 0x24044));
        // Join packet 004CBA1E stores capacity here; +240ED is occupancy, NOT capacity.
        // Native 3103 handler 005170A2/00517107 cycles 2..8; 00510A6A renders capacity/2.
        int capacity = memory.Byte(Address(game, 0x240EC));
        if (capacity != 2 && capacity != 4 && capacity != 6 && capacity != 8)
            throw new SnapshotBusyException("Native capacity is not yet one of 2/4/6/8; refusing occupancy-based inference.");
        uint options = Decode(memory, Address(game, 0x240E0), data, keys);
        bool readyRequested = memory.Byte(Address(game, 0x7789C)) != 0;
        bool inputBlocked = NativeInputBlocked(memory, mode);
        uint view = memory.UInt32(0x00870164);
        bool startBlocked = mode != 9 || !Pointer(view) ||
            memory.Int32(Address(view, 0x1F4)) > 0 || memory.UInt16(Address(game, 0x19ED6)) == 25;
        if (memory.Byte(0x008F4A2C) != 0 || memory.UInt32(0x008701CC) != game ||
            memory.UInt32(0x008F4A1C) != data || memory.UInt32(0x008F4A24) != keys ||
            self != Decode(memory, Address(game, 0x1A634), data, keys) ||
            master != Decode(memory, Address(game, 0x1A640), data, keys) ||
            roomId != memory.UInt16(Address(game, 0x24044)) ||
            capacity != memory.Byte(Address(game, 0x240EC)) ||
            options != Decode(memory, Address(game, 0x240E0), data, keys) ||
            readyRequested != (memory.Byte(Address(game, 0x7789C)) != 0) ||
            inputBlocked != NativeInputBlocked(memory, mode) ||
            view != memory.UInt32(0x00870164) ||
            startBlocked != (mode != 9 || !Pointer(view) || memory.Int32(Address(view, 0x1F4)) > 0 ||
                memory.UInt16(Address(game, 0x19ED6)) == 25) ||
            !roster.SequenceEqual(memory.Read(Address(game, 0x24165), roster.Length)) ||
            memory.Int32(0x0087053C) != mode) throw new SnapshotBusyException();
        RoomState room = ParseRoom((int)self, (int)master, capacity, options, roster);
        room.Game = game; room.Mode = mode; room.RoomId = roomId;
        room.ReadyRequested = readyRequested; room.StartBlocked = startBlocked;
        room.InputBlocked = inputBlocked;
        return room;
    }

    static uint UiChild(LabClient.MemoryReader memory, uint parent, uint id)
    {
        uint head = memory.UInt32(Address(parent, 8));
        if (!Pointer(head)) return 0;
        uint node = memory.UInt32(head);
        for (int count = 0; node != head && count < 128; count++)
        {
            if (!Pointer(node)) return 0;
            uint child = memory.UInt32(Address(node, 8));
            if (!Pointer(child)) return 0;
            if (memory.UInt32(Address(child, 0x18)) == id && memory.UInt32(Address(child, 0x10)) == parent)
                return child;
            node = memory.UInt32(node);
        }
        return 0;
    }

    static bool NativeInputBlocked(LabClient.MemoryReader memory, int mode)
    {
        // Same verified XP scene/dialog-token guards as chat\bridge\NativeChat.cs; never click through a popup.
        const uint root = 0x008F4958;
        uint scene = UiChild(memory, root, mode == 9 ? 0x5Bu : 0x12Du);
        if (scene == 0 || memory.UInt32(root) != 0x579744 ||
            memory.UInt32(scene) != (mode == 9 ? 0x57AF3Cu : 0x57AD6Cu)) return true;
        foreach (uint node in new[] { root, scene })
            if (memory.Byte(Address(node, 0x14)) != 0 || memory.Byte(Address(node, 0x50)) == 0 ||
                memory.Byte(Address(node, 0x52)) == 0) return true;
        return memory.UInt32(Address(root, 0x30)) != memory.UInt32(Address(scene, 0x30)) ||
            (memory.UInt32(0x005CDD04) != UInt32.MaxValue && memory.UInt32(0x00870578) == 0);
    }

    static RoomInput RoomAction(RoomState room)
    {
        if (room.Mode != 9 || room.InputBlocked || !TeamNames.Skip(1).Contains(room.SelfName) ||
            RosterIssue(room, true, false) != null ||
            room.States.Any(state => state != 0 && state != 1 && state != 3)) return RoomInput.None;
        if (room.Teams[room.SelfSlot] != DesiredTeam(room, room.SelfName))
        {
            if (room.States[room.SelfSlot] == 3 && room.ReadyRequested) return RoomInput.Unready;
            if (room.States[room.SelfSlot] == 1 && !room.ReadyRequested) return RoomInput.SwitchTeam;
            return RoomInput.None;
        }
        if (RosterIssue(room, true, true) != null) return RoomInput.None;
        if (room.MasterSlot == room.SelfSlot)
            return Enumerable.Range(0, 8).All(slot => slot == room.SelfSlot || room.States[slot] == 0 ||
                room.States[slot] == 3) && !room.StartBlocked ? RoomInput.Start : RoomInput.None;
        return room.States[room.SelfSlot] == 1 && !room.ReadyRequested ? RoomInput.Ready : RoomInput.None;
    }

    static string RoomWait(RoomState room)
    {
        string issue = RosterIssue(room, true, false);
        if (issue != null) return "Paused: " + issue;
        if (room.InputBlocked) return "Paused: the native scene is hidden/disabled or another dialog owns input.";
        if (room.States.Any(state => state == 2)) return "Waiting for native joins to finish; no room input.";
        if (room.States.Any(state => state == 4))
            return "Native match start is in progress; waiting for battle.";
        if (room.Teams[room.SelfSlot] != DesiredTeam(room, room.SelfName))
            return "Waiting to unready/correct " + room.SelfName + "'s native team; Player will not be automated.";
        issue = RosterIssue(room, true, true);
        if (issue != null) return issue;
        if (room.SelfName == "Player")
            return room.MasterSlot == room.SelfSlot ? "Player is human host; Start remains manual." :
                "Player remains manual; no Ready/Start input is authorized for the human.";
        if (room.MasterSlot == room.SelfSlot)
            return room.SelfName + " is master; waiting for every other participant's Ready and native start eligibility.";
        return room.States[room.SelfSlot] == 3 ? room.SelfName + " Ready is server-confirmed; Player starts manually." :
            "Waiting for the server to confirm " + room.SelfName + "'s Ready request.";
    }

    static uint[] UnitPointers(Func<uint, uint> read, uint game)
    {
        // Native lookup 00526940/00526AD0: type-list head, type 186A1, circular unit list.
        // ponytail: cap traversal at 256 groups/8 Solo units; other layouts require a verified profile.
        uint head = read(Address(game, 0x7713C));
        if (!Pointer(head)) throw new SnapshotBusyException("Native unit registry is not published.");
        uint group = read(Address(head, 0x1C));
        var seen = new HashSet<uint>();
        while (group != head)
        {
            if (!Pointer(group) || !seen.Add(group) || seen.Count > 256)
                throw new SnapshotBusyException("Native unit type list is not coherent.");
            uint type = read(Address(group, 4));
            if (type == 0x186A1) break;
            if (type > 0x186A1) throw new SnapshotBusyException("Native mobile group is not published.");
            group = read(Address(group, 0x1C));
        }
        if (group == head) throw new SnapshotBusyException("Native mobile group is absent.");
        var units = new uint[8];
        seen.Clear();
        uint unit = read(Address(group, 0x10));
        while (unit != group)
        {
            if (!Pointer(unit) || !seen.Add(unit) || seen.Count > 8)
                throw new SnapshotBusyException("Native Solo unit list is not coherent.");
            uint slot = read(Address(unit, 8));
            if (slot >= 8 || units[slot] != 0 || read(Address(unit, 4)) != 0x186A1)
                throw new InvalidDataException("Duplicate, secondary or unsupported native mobile identity.");
            units[slot] = unit;
            unit = read(Address(unit, 0x10));
        }
        return units;
    }

    static bool Living(uint aliveFlag, int health)
    {
        if (aliveFlag > 1 || health < -100000 || health > 100000)
            throw new InvalidDataException("Unsupported native life/health value.");
        return aliveFlag == 1 && health > 0;
    }

    static UnitState[] ReadUnits(LabClient.MemoryReader memory, RoomState room, uint data, uint keys)
    {
        uint[] pointers = UnitPointers(memory.UInt32, room.Game);
        var result = new UnitState[8];
        for (int slot = 0; slot < 8; slot++)
        {
            uint unit = pointers[slot];
            if ((unit != 0) != (room.States[slot] != 0))
                throw new SnapshotBusyException("Waiting for all named battle units; life is not inferred from occupancy.");
            if (unit == 0) continue;
            if ((Decode(memory, Address(unit, 0x98), data, keys) & 255) != 1 ||
                memory.Byte(Address(unit, 0x14)) != 0)
                throw new SnapshotBusyException("Waiting for the primary, non-deleting native mobile.");
            // Native health bar 004693D5 uses +21C / (+214 + +22C).
            // 'dead' at 004E9CD3 clears +2D4 at 004E9D17; HP also gates turns at 00441F62.
            int health = unchecked((int)Decode(memory, Address(unit, 0x21C), data, keys));
            long maximum = (long)unchecked((int)Decode(memory, Address(unit, 0x214), data, keys)) +
                unchecked((int)Decode(memory, Address(unit, 0x22C), data, keys));
            if (maximum < 1 || maximum > 100000)
                throw new SnapshotBusyException("Native maximum health is not published for " + room.Names[slot] + ".");
            var current = new UnitState {
                Pointer = unit, Slot = slot, Name = room.Names[slot], Team = room.Teams[slot],
                Health = health, MaximumHealth = (int)maximum,
                Alive = Living(Decode(memory, Address(unit, 0x2D4), data, keys) & 255, health),
                X = unchecked((int)Decode(memory, Address(unit, 0xA0), data, keys)),
                Y = unchecked((int)Decode(memory, Address(unit, 0xA8), data, keys)),
                Width = unchecked((int)Decode(memory, Address(unit, 0xB0), data, keys)),
                Height = unchecked((int)Decode(memory, Address(unit, 0xC0), data, keys))
            };
            if (health > maximum ||
                current.Width < 4 || current.Width > 128 || current.Height < 8 || current.Height > 160 ||
                (current.Alive && (current.X < 0 || current.X > 4096 || current.Y < -4096 || current.Y > 8192)))
                throw new SnapshotBusyException("Native body/health/position is outside the supported profile for " + room.Names[slot] + ".");
            result[slot] = current;
        }
        if (!pointers.SequenceEqual(UnitPointers(memory.UInt32, room.Game)))
            throw new SnapshotBusyException("The native mobile list changed during observation.");
        return result;
    }

    static bool SameRoom(RoomState first, RoomState second)
    {
        return first.Mode == second.Mode && first.RoomId == second.RoomId && first.Capacity == second.Capacity &&
            first.Options == second.Options && first.MasterSlot == second.MasterSlot &&
            first.Names.SequenceEqual(second.Names) && first.States.SequenceEqual(second.States) &&
            first.Teams.SequenceEqual(second.Teams);
    }

    static State Read(LabClient.MemoryReader memory, LabClient.MemoryReader human)
    {
        var state = new State { Mode = memory.Int32(0x0087053C) };
        if (state.Mode != 11) return state;
        if (memory.Byte(0x008F4A2C) != 0) throw new SnapshotBusyException();
        state.Game = memory.UInt32(0x008701CC);
        if (!Pointer(state.Game)) throw new SnapshotBusyException();
        state.Unit = memory.UInt32(Address(state.Game, 0x26E04));
        state.Active = memory.UInt32(Address(state.Game, 0x26E08));
        uint data = memory.UInt32(0x008F4A1C), keys = memory.UInt32(0x008F4A24);
        if (!Pointer(state.Unit) || !Pointer(state.Active) || !Pointer(data) || !Pointer(keys))
            throw new SnapshotBusyException();
        state.Slot = memory.Byte(0x008F3929);
        uint activeSlot = memory.UInt32(Address(state.Active, 8));
        if (activeSlot >= 8) throw new SnapshotBusyException("Native active slot is outside the verified eight-slot table.");
        state.ActiveSlot = (int)activeSlot;
        state.Battle = memory.UInt32(0x0087016C);
        if (!Pointer(state.Battle)) throw new SnapshotBusyException();
        uint turnNumber = Decode(memory, Address(state.Game, 0x28E4C), data, keys);
        if (turnNumber > UInt16.MaxValue || memory.Int32(Address(state.Battle, 0x10A0)) != state.ActiveSlot)
            throw new SnapshotBusyException("Waiting for matching native turn number and actor.");
        state.TurnNumber = (int)turnNumber;
        state.Room = ReadRoom(memory, 11);
        string issue = RosterIssue(state.Room, true, true);
        if (issue != null) throw new InvalidDataException(issue);
        if (botAccount != null && state.Room.SelfName != botAccount)
            throw new InvalidDataException("Native self identity " + state.Room.SelfName + " does not match instance " + botAccount + ".");
        if (state.Room.Game != state.Game || state.Room.SelfSlot != state.Slot ||
            state.Room.States.Any(value => value != 0 && value != 4))
            throw new SnapshotBusyException("Waiting for the complete native battle roster to settle.");
        if (human != null)
        {
            RoomState peer = ReadRoom(human, 11);
            if (peer.SelfName != "Player" || !SameRoom(state.Room, peer))
                throw new SnapshotBusyException("Legacy human PID is not the verified Player in this battle.");
        }
        state.Units = ReadUnits(memory, state.Room, data, keys);
        state.TargetSlot = ObservedTarget(state);
        if (state.Units[state.Slot].Pointer != state.Unit || state.Units[state.ActiveSlot].Pointer != state.Active)
            throw new SnapshotBusyException("The native self/active pointers do not match the verified mobile list.");
        state.SelfAlive = state.Units[state.Slot].Alive;
        state.Mobile = memory.Byte(0x00897368);
        state.Angle = unchecked((int)Decode(memory, Address(state.Unit, 0x1F0), data, keys));
        uint turn = Decode(memory, Address(state.Unit, 0x29C), data, keys) & 255;
        if (turn > 1 || state.Angle < -180 || state.Angle > 180)
            throw new SnapshotBusyException();
        state.Turn = turn == 1;
        state.Charge = Decode(memory, Address(state.Unit, 0x254), data, keys);
        byte[] players = memory.Read(0x00882A58, 8 * 0x18);
        int own = state.Slot * 0x18;
        state.X = state.Units[state.Slot].X;
        state.Y = state.Units[state.Slot].Y;
        state.Slope = BitConverter.ToInt32(players, own + 8);
        state.Facing = players[own + 12];
        if (state.SelfAlive && (state.X != BitConverter.ToUInt16(players, own) ||
            state.Y != BitConverter.ToUInt16(players, own + 4)))
            throw new SnapshotBusyException("Native mobile position and calibrated input telemetry disagree.");
        if (state.TargetSlot >= 0)
        {
            state.TargetName = state.Room.Names[state.TargetSlot];
            state.TargetX = state.Units[state.TargetSlot].X;
            state.TargetY = state.Units[state.TargetSlot].Y - state.Units[state.TargetSlot].Height / 2.0;
        }
        state.Wind = memory.Byte(Address(state.Battle, 0x1234));
        state.WindDirection = memory.UInt16(Address(state.Battle, 0x1235));
        if (state.Facing > 1 || state.Slope < -360 || state.Slope > 360 ||
            state.Wind > 40 || state.WindDirection >= 360)
            throw new InvalidDataException("Observed physics values do not match the supported client profile.");
        UnitState[] verified = ReadUnits(memory, state.Room, data, keys);
        if (!state.Units.Select(unit => unit == null ? null : unit.Key)
                .SequenceEqual(verified.Select(unit => unit == null ? null : unit.Key)) ||
            state.Room.Key != ReadRoom(memory, 11).Key ||
            !players.SequenceEqual(memory.Read(0x00882A58, players.Length)) ||
            memory.Byte(0x008F4A2C) != 0 || memory.UInt32(0x008701CC) != state.Game ||
            memory.UInt32(0x008F4A1C) != data || memory.UInt32(0x008F4A24) != keys ||
            memory.UInt32(0x0087016C) != state.Battle ||
            turnNumber != Decode(memory, Address(state.Game, 0x28E4C), data, keys) ||
            memory.Int32(Address(state.Battle, 0x10A0)) != state.ActiveSlot ||
            memory.UInt32(Address(state.Game, 0x26E04)) != state.Unit ||
            memory.UInt32(Address(state.Game, 0x26E08)) != state.Active ||
            memory.Int32(0x0087053C) != 11)
            throw new SnapshotBusyException();
        return state;
    }

    static State Stable(LabClient.MemoryReader memory, LabClient.MemoryReader human)
    {
        SnapshotBusyException busy = null;
        for (int attempt = 0; attempt < 4; attempt++)
        {
            try { return Read(memory, human); }
            catch (SnapshotBusyException error) { busy = error; Thread.Sleep(5); }
        }
        throw busy ?? new SnapshotBusyException();
    }

    static AimState ReadAim(LabClient.MemoryReader memory, State state)
    {
        uint data = memory.UInt32(0x008F4A1C), keys = memory.UInt32(0x008F4A24);
        if (!Pointer(data) || !Pointer(keys) || memory.Byte(0x008F4A2C) != 0) throw new SnapshotBusyException();
        var aim = new AimState {
            GunAngle = unchecked((int)Decode(memory, Address(state.Unit, 0x198), data, keys)),
            WorldAngle = unchecked((int)Decode(memory, Address(state.Unit, 0x1B0), data, keys)),
            Minimum = unchecked((int)Decode(memory, Address(state.Unit, 0x110), data, keys)),
            Maximum = unchecked((int)Decode(memory, Address(state.Unit, 0x108), data, keys)),
            Minimum1 = unchecked((int)Decode(memory, Address(state.Unit, 0x120), data, keys)),
            Maximum1 = unchecked((int)Decode(memory, Address(state.Unit, 0x118), data, keys)),
            Minimum2 = unchecked((int)Decode(memory, Address(state.Unit, 0x130), data, keys)),
            Maximum2 = unchecked((int)Decode(memory, Address(state.Unit, 0x128), data, keys)),
            MoveRemaining = checked((int)Decode(memory, Address(state.Unit, 0x284), data, keys)),
            MoveMaximum = checked((int)Decode(memory, Address(state.Unit, 0x27C), data, keys)),
            Width = checked((int)Decode(memory, Address(state.Unit, 0xB0), data, keys)),
            Height = checked((int)Decode(memory, Address(state.Unit, 0xC0), data, keys)),
            ShotMode = (Decode(memory, Address(state.Unit, 0x2CC), data, keys) & 255) != 0 ? 2 :
                (Decode(memory, Address(state.Unit, 0x2C4), data, keys) & 255) != 0 ? 1 : 0
        };
        if (memory.Byte(0x008F4A2C) != 0 || data != memory.UInt32(0x008F4A1C) ||
            keys != memory.UInt32(0x008F4A24)) throw new SnapshotBusyException();
        if (new[] { aim.GunAngle, aim.WorldAngle, aim.Minimum, aim.Maximum, aim.Minimum1, aim.Maximum1, aim.Minimum2, aim.Maximum2 }.Any(a => a < -360 || a > 360) ||
            aim.Minimum > aim.Maximum ||
            aim.MoveRemaining < 0 || aim.MoveRemaining > 100000 || aim.MoveMaximum <= 0 || aim.MoveMaximum > 100000 ||
            aim.Width < 4 || aim.Width > 128 || aim.Height < 8 || aim.Height > 160)
            throw new InvalidDataException("Native aiming/body/movement telemetry is outside the verified profile.");
        return aim;
    }

    static ArmorBallistics.Terrain ReadTerrain(LabClient.MemoryReader memory, State state)
    {
        uint map = Address(state.Game, 0x76894);
        byte[] header = memory.Read(Address(map, 0x18), 0x20);
        int width = BitConverter.ToInt32(header, 0), height = BitConverter.ToInt32(header, 4);
        uint pixels = BitConverter.ToUInt32(header, 0x1C);
        if (width < 64 || height < 64 || width > 4096 || height > 4096 || !Pointer(pixels))
            throw new SnapshotBusyException("The native terrain mask is not available.");
        int size = checked(width * height);
        byte[] mask = memory.ReadRegion(pixels, size);
        byte[] verified = memory.ReadRegion(pixels, size);
        if (!mask.SequenceEqual(verified) || memory.Int32(Address(map, 0x18)) != width ||
            memory.Int32(Address(map, 0x1C)) != height || memory.UInt32(Address(map, 0x34)) != pixels ||
            memory.UInt32(0x008701CC) != state.Game || memory.UInt32(0x0087016C) != state.Battle ||
            memory.Int32(0x0087053C) != 11) throw new SnapshotBusyException("Terrain changed while it was being observed.");
        return new ArmorBallistics.Terrain(width, height, mask);
    }

    static void Event(string name, object details)
    {
        if (log != null) log.WriteLine(Json.Serialize(new { time = DateTime.UtcNow.ToString("o"),
            bot = BotName, name = name, details = details }));
    }

    static bool ImpactOwner(uint expectedUnit, int expectedTurn, uint activeUnit, int turn, bool actionable)
    {
        return expectedUnit == activeUnit && (expectedTurn == turn || !actionable);
    }

    static int DigFailures(State state)
    {
        return excavationTarget != null && excavationTarget.Game == state.Game && excavationTarget.Battle == state.Battle &&
            excavationTarget.TargetSlot == state.TargetSlot && Math.Abs(excavationTarget.TargetX - state.TargetX) < 64 &&
            Math.Abs(excavationTarget.TargetY - state.TargetY) < 64 ? failedExcavations : 0;
    }

    static bool ApplyImpactFeedback(PendingImpact pending, ArmorBallistics.TerrainChange change, bool usable)
    {
        if (pending.Excavation)
        {
            bool progress = usable && change != null &&
                (change.CenterX - pending.Shot.LandingX) * (change.CenterX - pending.Shot.LandingX) +
                (change.CenterY - pending.Shot.LandingY) * (change.CenterY - pending.Shot.LandingY) <= 64 * 64;
            // ponytail: two digs without localized observed progress exhaust excavation for an unchanged target.
            // Missing attribution also consumes a try; direct shots/moves remain available. A longer retry
            // policy needs measured impact attribution, not repeated faith in the same predicted obstruction.
            failedExcavations = progress ? 0 : Math.Min(2, DigFailures(pending.Turn) + 1);
            excavationTarget = pending.Turn;
            return progress;
        }
        if (usable && change != null && !pending.MemoryRecorded)
        {
            if (change.NearestTargetDistance > 64)
            {
                repeatedMisses = Math.Abs(missedX - pending.Turn.X) < 24 &&
                    Math.Abs(missedAngle - pending.WorldAngle) < 6 ? Math.Min(4, repeatedMisses + 1) : 1;
                missedAngle = pending.WorldAngle; missedX = pending.Turn.X;
                missedTargetX = pending.Turn.TargetX; missedTargetY = pending.Turn.TargetY;
            }
            else
            {
                repeatedMisses = 0;
                excavationTarget = null; failedExcavations = 0;
            }
        }
        return false;
    }

    static void ObserveCharge(int requested, int observed)
    {
        if (requested < 40 || requested > 400 || observed < 0 || observed > 400)
            throw new InvalidDataException("Observed native charge is outside the supported HUD range.");
        chargeUncertainty = Math.Max(chargeUncertainty, Math.Abs(requested - observed) + 2);
    }

    static bool ObserveGoodShot(PendingImpact pending, UnitState[] units, bool owned)
    {
        if (!owned || pending.Excavation || pending.MemoryRecorded || pending.ObservedPower < 40 ||
            pending.ObservedPower > 400 || pending.Turn.TargetSlot < 0 || units == null || units.Length != 8) return false;
        UnitState before = pending.Turn.Units[pending.Turn.TargetSlot], after = units[pending.Turn.TargetSlot];
        if (after == null || after.Pointer != before.Pointer || after.Health >= before.Health || after.Health < 0) return false;
        pending.MemoryRecorded = true;
        bool eligible = after.Alive && after.X == before.X && after.Y == before.Y;
        Event("target-hp-decrease", new { turn = pending.Turn.TurnNumber, targetSlot = pending.Turn.TargetSlot,
            healthBefore = before.Health, healthAfter = after.Health, weapon = pending.Weapon,
            evidence = "intended-target HP decreased after the last guarded pre-release snapshot, observed during owned flight; weather/falls may contribute",
            directHitConfirmed = false, memoryEligible = eligible });
        if (eligible)
        {
            repeatedMisses = 0;
            string key = TerrainKey(pending.Before), weaponKey = WeaponKey(pending.Weapon);
            GoodShots.RemoveAll(m => m.Weapon == pending.Weapon && m.WeaponKey == weaponKey &&
                m.TerrainKey == key && SameScene(m.Context, pending.Turn));
            GoodShots.Insert(0, new ShotMemory { Context = pending.Turn, TerrainKey = key, WeaponKey = weaponKey,
                Weapon = pending.Weapon, GunAngle = pending.GunAngle, Power = pending.ObservedPower });
            if (GoodShots.Count > 4) GoodShots.RemoveAt(4);
        }
        return true;
    }

    static void ObserveImpact(LabClient.MemoryReader memory)
    {
        PendingImpact pending = pendingImpact;
        if (pending == null) return;
        if (pending.Watch.ElapsedMilliseconds > 12000)
        {
            if (!pending.FeedbackRecorded) ApplyImpactFeedback(pending, null, false);
            Event("impact-unconfirmed", new { turn = pending.Turn.TurnNumber,
                intent = pending.Excavation ? "excavation" : "direct", failedExcavations = DigFailures(pending.Turn),
                reason = "No attributable terrain progress within the observation window." });
            pendingImpact = null;
            return;
        }
        if (pending.Watch.ElapsedMilliseconds < pending.NextSample) return;
        pending.NextSample = pending.Watch.ElapsedMilliseconds + 250;
        try
        {
            Func<bool> ownedFlight = delegate {
                if (memory.Int32(0x0087053C) != 11 || memory.UInt32(0x008701CC) != pending.Turn.Game ||
                    memory.UInt32(0x0087016C) != pending.Turn.Battle || memory.Byte(0x008F4A2C) != 0) return false;
                uint data = memory.UInt32(0x008F4A1C), keys = memory.UInt32(0x008F4A24);
                if (!Pointer(data) || !Pointer(keys)) return false;
                int turn = checked((int)Decode(memory, Address(pending.Turn.Game, 0x28E4C), data, keys));
                bool actionable = (Decode(memory, Address(pending.Turn.Unit, 0x29C), data, keys) & 255) != 0;
                return ImpactOwner(pending.Turn.Unit, pending.Turn.TurnNumber,
                    memory.UInt32(Address(pending.Turn.Game, 0x26E08)), turn, actionable);
            };
            if (!ownedFlight())
            {
                if (!pending.FeedbackRecorded) ApplyImpactFeedback(pending, null, false);
                Event("impact-unconfirmed", new { turn = pending.Turn.TurnNumber,
                    intent = pending.Excavation ? "excavation" : "direct", failedExcavations = DigFailures(pending.Turn),
                    reason = "The active projectile/turn owner changed." });
                pendingImpact = null; return;
            }
            ArmorBallistics.Terrain after = ReadTerrain(memory, pending.Turn);
            State observed = Stable(memory, null);
            if (!ownedFlight() || observed.Room == null || observed.Room.Key != pending.Turn.Room.Key) return;
            ObserveGoodShot(pending, observed.Units, true);
            if (pending.FeedbackRecorded)
            {
                if (pending.MemoryRecorded) pendingImpact = null;
                return;
            }
            ArmorBallistics.TerrainChange change = ArmorBallistics.CompareTerrain(pending.Before, after,
                pending.Turn.TargetX, pending.Turn.TargetY);
            if (change == null || change.RemovedPixels < 16) return;
            uint target = checked(0x00882A58u + (uint)pending.Turn.TargetSlot * 0x18u);
            bool usable = change.RemovedPixels >= 16 && change.MaximumX - change.MinimumX <= 180 &&
                change.MaximumY - change.MinimumY <= 180 &&
                Math.Abs(memory.UInt16(target) - pending.Turn.TargetX) < 12;
            bool excavationProgress = ApplyImpactFeedback(pending, change, usable);
            pending.FeedbackRecorded = true;
            Event("terrain-impact", new { turn = pending.Turn.TurnNumber, targetSlot = pending.Turn.TargetSlot,
                targetName = pending.Turn.TargetName, source = "native-mask-difference-during-shot-turn",
                intent = pending.Excavation ? "excavation" : "direct", excavationProgressObserved = excavationProgress,
                failedExcavations = DigFailures(pending.Turn),
                footprint = change, directHitConfirmed = false, feedbackUsable = usable });
            if (pending.Excavation || pending.MemoryRecorded) pendingImpact = null;
        }
        catch (SnapshotBusyException) { pending.NextSample = pending.Watch.ElapsedMilliseconds + 250; }
    }

    static void Status(string message)
    {
        if (message == lastStatus) return;
        lastStatus = message;
        Console.WriteLine(message);
        Event("status", message);
    }

    static bool ForegroundAllowed(uint owner, int? humanPid, int botPid)
    {
        return owner == botPid || (humanPid.HasValue && owner == humanPid.Value);
    }

    static bool GameHasFocus(int? humanPid, int botPid, RoomState room = null)
    {
        uint owner;
        LabClient.GetWindowThreadProcessId(LabClient.GetForegroundWindow(), out owner);
        if (owner == botPid) return true;
        if (room == null) return ForegroundAllowed(owner, humanPid, botPid);
        if (owner == 0 || owner > Int32.MaxValue) return false;
        try
        {
            using (var peer = new LabClient.MemoryReader((int)owner, true))
            {
                RoomState observed = ReadRoom(peer, room.Mode);
                return !observed.InputBlocked && RosterIssue(observed, true, false) == null && SameRoom(room, observed) &&
                    (!humanPid.HasValue || owner != humanPid.Value || observed.SelfName == "Player");
            }
        }
        catch (SnapshotBusyException) { return false; }
        catch (Win32Exception) { return false; }
        catch (InvalidOperationException) { return false; }
        catch (ArgumentException) { return false; }
        catch (IOException) { return false; }
    }

    static string SingletonName(string root)
    {
        using (var hash = SHA256.Create())
            return @"Local\GunBoundAILab.BotController." + BitConverter.ToString(hash.ComputeHash(
                Encoding.UTF8.GetBytes(Path.GetFullPath(root).TrimEnd('\\').ToUpperInvariant()))).Replace("-", "");
    }

    static bool OwnsInput { get { return Volatile.Read(ref inputOwnerThread) == Thread.CurrentThread.ManagedThreadId; } }

    static void RequireInputOwnership()
    {
        if (!OwnsInput) throw new InvalidOperationException("Guest input requires exclusive " + GuestInputMutex + " ownership.");
    }

    static string GuestInputFaultPath(string root)
    {
        root = Path.GetFullPath(root).TrimEnd('\\');
        return new[] { @"C:\GunBoundAI", @"C:\GunBoundAI\instances\BotOne",
            @"C:\GunBoundAI\instances\BotTwo", @"C:\GunBoundAI\instances\BotThree" }
            .Contains(root, StringComparer.OrdinalIgnoreCase) ? @"C:\GunBoundAI\session\guest-input-fault.json" : null;
    }

    static bool FaultPresent(string path, Func<string, FileAttributes> attributes = null)
    {
        if (path == null) return false;
        if (attributes == null) attributes = File.GetAttributes;
        try { attributes(path); return true; }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
        catch { return true; }
    }

    static void RequireNoInputFault()
    {
        if (!inputFaultObserved && !FaultPresent(inputFaultFile)) return;
        inputFaultObserved = true;
        RequestStop("guest-input-fault");
        throw new InvalidOperationException("Sticky guest input fault: parent/manual verified recovery is required; no new input.");
    }

    static byte[] InputFaultBytes(string name, string root, int pid, string path, long startedUtcTicks, string diagnostic)
    {
        diagnostic = diagnostic ?? "";
        int length = Math.Min(512, diagnostic.Length);
        string issuedUtc = DateTime.UtcNow.ToString("o");
        for (;;)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(Json.Serialize(new {
                schemaVersion = 1, @event = name, issuedUtc = issuedUtc, sourceRoot = root,
                process = new { pid = pid, path = path, startedUtcTicks = startedUtcTicks },
                diagnostic = diagnostic.Substring(0, length)
            }) + Environment.NewLine);
            if (bytes.Length <= 4096) return bytes;
            if (length == 0) throw new InvalidDataException("Guest input fault identity exceeds the 4096-byte signal limit.");
            // ponytail: halve diagnostic text to meet the byte ceiling; process identity is never truncated.
            length /= 2;
        }
    }

    static void PublishInputFault(string name, string diagnostic)
    {
        if (inputFaultFile == null) return;
        RequireInputOwnership();
        if (name != "guest-input-abandoned" && name != "input-cleanup-failed")
            throw new ArgumentException("Unsupported guest input fault event.");
        inputFaultObserved = true;
        RequestStop("guest-input-fault");
        if (FaultPresent(inputFaultFile)) return;
        using (var process = Process.GetCurrentProcess())
        {
            byte[] bytes = InputFaultBytes(name, LabClient.Root, process.Id, process.MainModule.FileName,
                process.StartTime.ToUniversalTime().Ticks, diagnostic);
            Directory.CreateDirectory(Path.GetDirectoryName(inputFaultFile));
            try
            {
                // CreateNew atomically publishes unsafe presence, never overwriting an earlier fault.
                // Partial/unreadable payloads remain sticky too; recovery must not depend on parsing this JSON.
                using (var file = new FileStream(inputFaultFile, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    file.Write(bytes, 0, bytes.Length);
                    file.Flush(true);
                }
            }
            catch
            {
                if (!FaultPresent(inputFaultFile)) throw;
            }
        }
    }

    static bool TryAcquireInput(Mutex mutex, out bool abandoned)
    {
        abandoned = false;
        if (OwnsInput) throw new InvalidOperationException("Nested controller input transactions are not supported.");
        RequireNoInputFault();
        bool acquired;
        try { acquired = mutex.WaitOne(0); }
        catch (AbandonedMutexException) { acquired = true; abandoned = true; }
        if (acquired)
        {
            Volatile.Write(ref inputOwnerThread, Thread.CurrentThread.ManagedThreadId);
            if (abandoned) PublishInputFault("guest-input-abandoned", "Abandoned input ownership; no foreign key releases.");
            else RequireNoInputFault();
        }
        return acquired;
    }

    static void EndInput(Mutex mutex, Action cleanup)
    {
        if (!OwnsInput) return;
        try { cleanup(); }
        catch (Exception error)
        {
            try { PublishInputFault("input-cleanup-failed", error.Message); }
            finally { Event("input-cleanup-failed", error.Message); }
            throw;
        }
        finally { Volatile.Write(ref inputOwnerThread, 0); mutex.ReleaseMutex(); }
    }

    static bool InputsIdle(Func<int, bool> held)
    {
        return !Enumerable.Range(1, 255).Any(held);
    }

    static bool InputsIdle()
    {
        return InputsIdle(key => (GetAsyncKeyState(key) & 0x8000) != 0);
    }

    static bool PeerInMode(LabClient.MemoryReader human, int mode)
    {
        return human == null || human.Int32(0x0087053C) == mode;
    }

    static void RequestStop(string reason)
    {
        Interlocked.CompareExchange(ref stopReason, reason, null);
        stopping = true;
    }

    static bool StopRequested(string stopFile)
    {
        if (!stopping && File.Exists(stopFile)) RequestStop("stop-file");
        return stopping;
    }

    static bool ClientExited(Process botProcess, Process humanProcess)
    {
        botProcess.Refresh();
        if (botProcess.HasExited)
        {
            RequestStop("bot-client-exit");
            Status(BotName + "'s client closed; stopping its controller.");
            return true;
        }
        if (humanProcess != null)
        {
            humanProcess.Refresh();
            if (humanProcess.HasExited)
            {
                RequestStop("human-client-exit");
                Status("The human client closed; stopping " + BotName + ".");
                return true;
            }
        }
        return false;
    }

    static bool OnConsoleExit(uint kind)
    {
        RequestStop(kind == 0 ? "console-ctrl-c" : kind == 1 ? "console-ctrl-break" :
            kind == 2 ? "console-close" : kind == 5 ? "console-logoff" :
            kind == 6 ? "console-shutdown" : "console-signal-" + kind);
        // Console handlers run on another thread. The owning transaction performs its own abort/release.
        return true;
    }

    static bool CanRetryShot(bool chargeAttempted, int unavailableFailures)
    {
        return !chargeAttempted && unavailableFailures < 2;
    }

    static void AbandonTurn(string reason, bool chargeAttempted)
    {
        Event("turn-abandoned", new { reason = reason, chargeAttempted = chargeAttempted, shotOutcomeUnknown = chargeAttempted });
        Status(BotName + " turn abandoned; no retry this turn: " + reason);
    }

    static void ReportSkippedTurn(bool observed, string outcome, string reason)
    {
        if (!observed || outcome != null) return;
        Event("turn-skipped", new { reason = reason });
        Status(BotName + " turn skipped without a shot: " + reason);
    }

    static void Muzzle(double sourceX, double sourceY, double slope, int facing, out double x, out double y,
        ArmorBallistics.ProjectileModel model = null)
    {
        double rotation = (slope + (facing == 0 ? 180 : 0)) * Math.PI / 180;
        double normal = rotation + (facing == 0 ? -Math.PI / 2 : Math.PI / 2);
        double offsetX = model == null ? (facing == 0 ? 21 : 20) :
            facing == 0 ? model.MuzzleForwardLeft : model.MuzzleForwardRight;
        double up = model == null ? 21 : model.MuzzleUp, body = model == null ? 40 : model.BodyOffsetY;
        x = sourceX + offsetX * Math.Cos(rotation) + up * Math.Cos(normal);
        y = sourceY - body - offsetX * Math.Sin(rotation) - up * Math.Sin(normal);
    }

    static double WorldAngle(State state, AimState aim, int gun, double slope, int facing = -1)
    {
        if (facing < 0) facing = state.Facing;
        double angle = (facing == state.Facing ? aim.WorldAngle : 180 - aim.WorldAngle + 2 * state.Slope) +
            (gun - aim.GunAngle) * (facing == 0 ? -1 : 1) + slope - state.Slope;
        while (angle > 180) angle -= 360;
        while (angle < -180) angle += 360;
        return angle;
    }

    static ArmorBallistics.Body[] FriendlyBodies(State state)
    {
        if (state.Room == null || RosterIssue(state.Room, true, true) != null)
            throw new InvalidDataException("Friendly-fire checks require the complete verified team roster.");
        if (Enumerable.Range(0, 8).Any(slot => (state.Room.States[slot] != 0) != (state.Units[slot] != null)))
            throw new InvalidDataException("A teammate position/life observation is missing.");
        return Enumerable.Range(0, 8).Where(slot => slot != state.Slot && state.Units[slot] != null &&
            state.Units[slot].Alive && state.Room.Teams[slot] == state.Room.Teams[state.Slot])
            .Select(slot => new ArmorBallistics.Body(state.Units[slot].X, state.Units[slot].Y,
                state.Units[slot].Width, state.Units[slot].Height)).ToArray();
    }

    static ArmorBallistics.Body[] OtherEnemyBodies(State state)
    {
        // ponytail: only opposing bodies here; shooter launch handling remains separate from terminal self-blast checks.
        return Enumerable.Range(0, 8).Where(slot => slot != state.TargetSlot && Enemy(state, slot))
            .Select(slot => new ArmorBallistics.Body(state.Units[slot].X, state.Units[slot].Y,
                state.Units[slot].Width, state.Units[slot].Height, slot)).ToArray();
    }

    static bool MoveClear(State state, double destination)
    {
        UnitState self = state.Units[state.Slot];
        if (self == null || !self.Alive) return false;
        return !state.Units.Any(unit => unit != null && unit.Slot != state.Slot && unit.Alive &&
            unit.Y >= state.Y - self.Height - 8 && unit.Y - unit.Height <= state.Y + 8 &&
            unit.X >= Math.Min(state.X, destination) - (self.Width + unit.Width) / 2.0 - 8 &&
            unit.X <= Math.Max(state.X, destination) + (self.Width + unit.Width) / 2.0 + 8);
    }

    static bool SameShotGeometry(State first, State second)
    {
        if (first.TargetSlot != second.TargetSlot || first.TargetSlot < 0 ||
            first.X != second.X || first.Y != second.Y || first.Facing != second.Facing ||
            first.Angle != second.Angle || first.Slope != second.Slope ||
            first.Wind != second.Wind || first.WindDirection != second.WindDirection) return false;
        for (int slot = 0; slot < 8; slot++)
        {
            UnitState before = first.Units[slot], after = second.Units[slot];
            if ((before == null) != (after == null)) return false;
            if (before != null && (before.Pointer != after.Pointer || before.Alive != after.Alive ||
                before.X != after.X || before.Y != after.Y || before.Width != after.Width || before.Height != after.Height))
                return false;
        }
        return true;
    }

    static string TerrainKey(ArmorBallistics.Terrain terrain)
    {
        using (var hash = SHA256.Create())
            return terrain.Width + ":" + terrain.Height + ":" + Convert.ToBase64String(hash.ComputeHash(terrain.Cells));
    }

    static bool SameScene(State first, State second, bool moving = false)
    {
        if (first.Game != second.Game || first.Battle != second.Battle || first.Unit != second.Unit ||
            first.Slot != second.Slot || first.TargetSlot != second.TargetSlot || first.Room.Key != second.Room.Key ||
            first.Wind != second.Wind || first.WindDirection != second.WindDirection ||
            (!moving && (first.X != second.X || first.Y != second.Y || first.Facing != second.Facing || first.Slope != second.Slope)))
            return false;
        for (int slot = 0; slot < 8; slot++)
        {
            UnitState a = first.Units[slot], b = second.Units[slot];
            if ((a == null) != (b == null)) return false;
            if (a != null && (a.Pointer != b.Pointer || a.Alive != b.Alive || a.Width != b.Width || a.Height != b.Height ||
                (!(moving && slot == first.Slot) && (a.X != b.X || a.Y != b.Y)))) return false;
        }
        return true;
    }

    static string WeaponKey(int weapon)
    {
        return weapon == 1 ? "Armor-S1-Euler-v1" : "Armor-S2:" + Json.Serialize(shot2);
    }

    static ShotMemory MemoryFor(State state, string terrainKey, int weapon)
    {
        if (!Enemy(state, state.TargetSlot)) return null;
        return GoodShots.FirstOrDefault(m => m.Weapon == weapon && m.WeaponKey == WeaponKey(weapon) &&
            m.TerrainKey == terrainKey && SameScene(m.Context, state));
    }

    static int[] MemoryAngles(State state, int weapon)
    {
        return GoodShots.Where(m => m.Weapon == weapon && m.WeaponKey == WeaponKey(weapon) &&
            m.Context.Battle == state.Battle && m.Context.Game == state.Game && m.Context.Unit == state.Unit &&
            m.Context.TargetSlot == state.TargetSlot && Enemy(state, state.TargetSlot) &&
            m.Context.Units[m.Context.TargetSlot].Pointer == state.Units[state.TargetSlot].Pointer)
            .Select(m => m.GunAngle).Distinct().ToArray();
    }

    static ArmorBallistics.ProjectileModel[] ProjectileModels(int weapon)
    {
        if (weapon == 1) return new ArmorBallistics.ProjectileModel[] { null };
        throw new InvalidDataException(shot2.DisabledReason + " No S1-physics fallback or SS is permitted.");
    }

    static bool Shot2Envelope(State state, double x, double y, double slope, int facing, int? gun = null, int? power = null)
    {
        return false;
    }

    static bool SafeTrajectory(State state, ArmorBallistics.Shot shot, double x, double y,
        ArmorBallistics.ProjectileModel model = null)
    {
        double selfMargin = model == null ? 40 : model.SelfMarginPixels;
        double blastMargin = model == null ? 64 : model.BlastMarginPixels;
        if (shot == null || shot.Power < 40 || shot.Power > 400 || shot.FriendlyBlocked ||
            (!shot.Clear && !shot.TerrainImpact && shot.End != ArmorBallistics.EndKind.OtherEnemy) ||
            (shot.LandingX - x) * (shot.LandingX - x) +
            (shot.LandingY - (y - 25)) * (shot.LandingY - (y - 25)) < selfMargin * selfMargin) return false;
        return !shot.TerrainImpact ||
            Math.Abs(shot.LandingX - x) >= Math.Max(96, state.Units[state.Slot].Width / 2.0 + blastMargin);
    }

    static bool UsableShot(State state, ArmorBallistics.Shot shot, double x, double y, double slope,
        int facing = -1, bool directAttempt = false)
    {
        if (!SafeTrajectory(state, shot, x, y)) return false;
        if (shot.Clear) return true;
        // A safe noisy interception may fire without changing the target lock; it earns no selected-target direct credit.
        if (directAttempt)
            return shot.End == ArmorBallistics.EndKind.OtherEnemy ||
                (shot.LandingX - state.TargetX) * (shot.LandingX - state.TargetX) +
                (shot.LandingY - state.TargetY) * (shot.LandingY - state.TargetY) <= 96 * 96;
        double mx, my;
        Muzzle(x, y, slope, facing < 0 ? state.Facing : facing, out mx, out my);
        // ponytail: keep excavation outside the native support span plus the 64px blast margin.
        // Closer digging needs measured crater/support loss; the existing direct-shot self margin is unchanged.
        return DigFailures(state) < 2 && shot.UsefulTerrainImpact(mx, my, state.TargetX, state.TargetY);
    }

    static Robustness AssessShot(State state, AimState aim, ArmorBallistics.Terrain terrain,
        double x, double y, double slope, int facing, int gun, int power, int weapon)
    {
        var result = new Robustness();
        UnitState target = state.Units[state.TargetSlot];
        var body = new ArmorBallistics.Body(target.X, target.Y, target.Width, target.Height, state.TargetSlot);
        ArmorBallistics.Body[] friendlies = FriendlyBodies(state);
        ArmorBallistics.Body[] otherEnemies = OtherEnemyBodies(state);
        ArmorBallistics.ProjectileModel[] models = ProjectileModels(weapon);
        // ponytail: nine equally weighted stress probes, NOT a probability distribution or physics calibration.
        // +/-1 native degree (censored at observed native limits) and at least +/-4 HUD power units;
        // observed charge error +2 can only widen the envelope. Out-of-range power probes fail closed.
        foreach (int da in new[] { -1, 0, 1 })
            foreach (int dp in new[] { -chargeUncertainty, 0, chargeUncertainty })
            {
                result.Samples++;
                if (!aim.Legal(gun) || power + dp < 40 || power + dp > 400) continue;
                int probedGun = Math.Max(aim.Minimum, Math.Min(aim.Maximum, gun + da));
                if (weapon == 2 && !Shot2Envelope(state, x, y, slope, facing, probedGun, power + dp)) continue;
                bool safe = true, direct = true;
                for (int index = 0; index < models.Length; index++)
                {
                    ArmorBallistics.ProjectileModel model = models[index];
                    double mx, my;
                    Muzzle(x, y, slope, facing, out mx, out my, model);
                    ArmorBallistics.Shot path = ArmorBallistics.Trace(terrain, mx, my, state.TargetX, state.TargetY,
                        WorldAngle(state, aim, probedGun, slope, facing), power + dp, state.WindDirection, state.Wind,
                        friendlies: friendlies, targetBody: body, model: model, otherEnemies: otherEnemies);
                    safe &= SafeTrajectory(state, path, x, y, model);
                    direct &= path.Clear && path.HitSlot == state.TargetSlot;
                    if (da == 0 && dp == 0 && index == 0) result.Nominal = path;
                }
                if (da == 0 && dp == 0) result.NominalDirect = safe && direct;
                if (safe) result.SafeSamples++;
                if (safe && direct) result.DirectSamples++;
            }
        return result;
    }

    static bool BetterShot(ShotPlan candidate, ShotPlan best)
    {
        return candidate != null && (best == null || (candidate.Shot.Clear && !best.Shot.Clear) ||
            (candidate.Shot.Clear == best.Shot.Clear && candidate.Score < best.Score -
            (!candidate.Shot.Clear && candidate.X != best.X ? 8 : 0)));
    }

    static ShotPlan SearchAt(State state, AimState aim, ArmorBallistics.Terrain terrain,
        double x, double y, double slope, double targetX, double targetY, int step,
        Stopwatch budget, string stopFile, ref int evaluated, bool fixedAngle = false, long deadline = 1600,
        int weapon = 1, string terrainKey = null, SearchStats stats = null)
    {
        ShotPlan best = null;
        if (weapon == 2 && !shot2.Available) return null;
        terrainKey = terrainKey ?? TerrainKey(terrain);
        int facing = state.TargetX >= x ? 1 : 0;
        if (facing != state.Facing && x == state.X && (aim.MoveRemaining <= 0 ||
            (activeDifficulty != null && movementSpent >= activeDifficulty.Behavior.MaxMovePixels)))
        { if (stats != null) stats.FacingUnavailable++; return null; }
        State prospective = state.Copy();
        prospective.X = x; prospective.Y = y; prospective.Slope = (int)Math.Round(slope); prospective.Facing = facing;
        ShotMemory learned = MemoryFor(prospective, terrainKey, weapon);
        int[] remembered = MemoryAngles(state, weapon);
        int minimum = aim.Minimum, maximum = aim.Maximum;
        var angles = fixedAngle ? (aim.Legal(aim.GunAngle) ? new[] { aim.GunAngle } : new int[0]) :
            Enumerable.Range(minimum, maximum - minimum + 1)
                .Where(a => aim.Legal(a) && (a % step == 0 || a == aim.GunAngle || a == minimum || a == maximum || remembered.Contains(a)))
                .OrderBy(a => remembered.Contains(a) ? 0 : 1).ThenBy(a => Math.Abs(a - aim.GunAngle)).ToArray();
        ArmorBallistics.ProjectileModel model = ProjectileModels(weapon)[0];
        double mx, my;
        Muzzle(x, y, slope, facing, out mx, out my, model);
        ArmorBallistics.Body[] friendlies = FriendlyBodies(state);
        ArmorBallistics.Body[] otherEnemies = OtherEnemyBodies(state);
        UnitState target = state.Units[state.TargetSlot];
        var targetBody = new ArmorBallistics.Body(target.X, target.Y, target.Width, target.Height, state.TargetSlot);
        foreach (int gun in angles)
        {
            if (StopRequested(stopFile) || budget.ElapsedMilliseconds >= Math.Min(1600, deadline)) break;
            double world = WorldAngle(state, aim, gun, slope, facing);
            if (Math.Cos(world * Math.PI / 180) * (targetX - mx) <= 0) continue;
            if (weapon == 2 && !Shot2Envelope(state, x, y, slope, facing, gun))
            { if (stats != null) stats.OutsideShot2Envelope++; continue; }
            evaluated++;
            if (stats != null) { stats.Angles++; if (x != state.X) stats.MovedAngles++; }
            bool locked = learned != null && gun == learned.GunAngle && x == state.X && y == state.Y &&
                slope == state.Slope && facing == state.Facing;
            ArmorBallistics.Shot shot = locked ? ArmorBallistics.Trace(terrain, mx, my, state.TargetX, state.TargetY,
                world, learned.Power, state.WindDirection, state.Wind, friendlies: friendlies, targetBody: targetBody,
                model: model, otherEnemies: otherEnemies) : null;
            if (shot == null || !shot.Clear || !SafeTrajectory(state, shot, x, y, model))
            {
                locked = false;
                shot = ArmorBallistics.SolveTerrain(terrain, mx, my, targetX, targetY,
                    world, state.WindDirection, state.Wind, friendlies: friendlies, targetBody: targetBody, model: model,
                    observe: stats == null ? null : new Action<ArmorBallistics.Shot>(stats.Observe), otherEnemies: otherEnemies);
            }
            if (shot == null) { if (stats != null) stats.NoUsablePower++; continue; }
            if (!SafeTrajectory(state, shot, x, y, model)) { if (stats != null) stats.SelfRisk++; continue; }
            if (weapon == 1 && !UsableShot(state, shot, x, y, slope, facing))
            {
                if (stats != null) { if (DigFailures(state) >= 2) stats.ExhaustedDigging++; else stats.UselessTerrain++; }
                continue;
            }
            Robustness confidence = AssessShot(state, aim, terrain, x, y, slope, facing, gun, shot.Power, weapon);
            if (!confidence.Safe || (weapon == 2 && (!confidence.NominalDirect || confidence.Percent < shot2.MinimumModelConfidencePercent)))
            { if (stats != null) stats.UnsafeVariations++; continue; }
            shot = confidence.Nominal;
            bool goodLock = locked && confidence.NominalDirect && confidence.Percent >= 80;
            double score = (100 - confidence.Percent) * 0.8 + shot.Error + shot.FlightSeconds * 0.4 +
                shot.Power * 0.003 + Math.Abs(gun - aim.GunAngle) * 0.02 + Math.Abs(x - state.X) * 0.18 +
                (aim.Bonus(gun) ? 0 : 3) + (facing == state.Facing ? 0 : 2) - (goodLock ? 6 : 0);
            if (shot.Clear && Math.Abs(targetX - missedTargetX) < 64 && Math.Abs(targetY - missedTargetY) < 64 &&
                Math.Abs(x - missedX) < 24 && Math.Abs(world - missedAngle) < 6) score += repeatedMisses * 15;
            var candidate = new ShotPlan { GunAngle = gun, X = x, Y = y, Slope = slope, Shot = shot, Score = score,
                TargetSlot = state.TargetSlot, Facing = facing, Weapon = weapon, Confidence = confidence,
                Learned = goodLock };
            if (BetterShot(candidate, best)) best = candidate;
        }
        return best;
    }

    static ShotPlan SupportedPosition(State state, AimState aim, ArmorBallistics.Terrain terrain, int x, SearchStats stats)
    {
        int direction = Math.Sign(x - state.X), y, marginY, half = Math.Max(2, aim.Width / 2);
        if (direction == 0 || Math.Abs(x - state.X) > 48 || Math.Abs(x - state.TargetX) < 64 ||
            RecentPositions.Any(previous => Math.Abs(previous - x) < 6)) return null;
        if (!MoveClear(state, x + direction * 8))
        { if (stats != null) stats.BodyBlockedMoves++; return null; }
        if (!terrain.Walk((int)state.X, (int)state.Y, x, half, aim.Height, out y) ||
            !terrain.Walk((int)state.X, (int)state.Y, x + direction * 8, half, aim.Height, out marginY))
        { if (stats != null) stats.UnsupportedMoves++; return null; }
        return new ShotPlan { X = x, Y = y, TargetSlot = state.TargetSlot, Facing = state.TargetX >= x ? 1 : 0,
            Slope = state.Slope + terrain.Slope(x, y, half, aim.Height) -
                terrain.Slope((int)state.X, (int)state.Y, half, aim.Height) };
    }

    static List<ShotPlan> Positions(State state, AimState aim, ArmorBallistics.Terrain terrain, bool allowMove,
        string terrainKey, SearchStats stats)
    {
        var positions = new List<ShotPlan> { new ShotPlan { X = state.X, Y = state.Y, Slope = state.Slope,
            TargetSlot = state.TargetSlot, Facing = state.Facing } };
        if (!allowMove || aim.MoveRemaining <= 0) return positions;
        // ponytail: two no-progress requests stop all planned moves in the unchanged scene, not just one destination.
        // Earlier unblocking needs measured native movement-cost/collision data; real scene changes permit replanning.
        if (moveGoal != null && moveGoal.NoProgress >= 2 && moveGoal.TerrainKey == terrainKey &&
            Enemy(state, moveGoal.Context.TargetSlot) &&
            SameScene(moveGoal.Context, ForTarget(state, moveGoal.Context.TargetSlot), true)) return positions;
        foreach (int distance in new[] { 12, 24, 36, 48 })
            foreach (int direction in new[] { -1, 1 })
            {
                if (distance > activeDifficulty.Behavior.MaxMovePixels - movementSpent) continue;
                ShotPlan position = SupportedPosition(state, aim, terrain, (int)state.X + distance * direction, stats);
                if (position != null) positions.Add(position);
            }
        return positions;
    }

    static ShotPlan ChoosePlan(State state, AimState aim, ArmorBallistics.Terrain terrain,
        double targetX, double targetY, string stopFile, bool allowMove, bool fixedAngle = false,
        Stopwatch sharedBudget = null, long deadline = 1600, int weapon = 1, string terrainKey = null, SearchStats stats = null)
    {
        Stopwatch budget = sharedBudget ?? Stopwatch.StartNew();
        terrainKey = terrainKey ?? TerrainKey(terrain);
        var positions = Positions(state, aim, terrain, allowMove, terrainKey, stats);
        int evaluated = 0, step = activeDifficulty.Behavior.AngleStepDegrees;
        long probeEnd = positions.Count > 1 && !fixedAngle ? Math.Max(budget.ElapsedMilliseconds, deadline - 100) : deadline;
        ShotPlan best = null;
        // ponytail: give every supported position a slice even when standing already looks clear.
        // One solver/probe group may overrun a slice; the whole enemy/position search shares 1600ms.
        for (int index = 0; index < positions.Count; index++)
        {
            if (StopRequested(stopFile) || budget.ElapsedMilliseconds >= probeEnd) break;
            ShotPlan position = positions[index];
            long end = Math.Min(probeEnd, budget.ElapsedMilliseconds +
                Math.Max(1, (probeEnd - budget.ElapsedMilliseconds) / (positions.Count - index)));
            ShotPlan candidate = SearchAt(state, aim, terrain, position.X, position.Y, position.Slope, targetX, targetY,
                positions.Count > 1 ? Math.Max(6, step) : step, budget, stopFile, ref evaluated, fixedAngle, end,
                weapon, terrainKey, stats);
            if (BetterShot(candidate, best)) best = candidate;
        }
        if (positions.Count > 1 && !fixedAngle && budget.ElapsedMilliseconds < deadline)
        {
            ShotPlan refined = SearchAt(state, aim, terrain, state.X, state.Y, state.Slope, targetX, targetY,
                step, budget, stopFile, ref evaluated, false, deadline, weapon, terrainKey, stats);
            if (BetterShot(refined, best)) best = refined;
        }
        return best;
    }

    static void ValidateGoal(State state, string terrainKey)
    {
        if (moveGoal == null) return;
        if (!Enemy(state, moveGoal.Context.TargetSlot) || moveGoal.TerrainKey != terrainKey ||
            !SameScene(moveGoal.Context, ForTarget(state, moveGoal.Context.TargetSlot), true))
        {
            Event("move-goal-invalidated", "Battle/roster/target/units/wind/terrain changed; no cached path authorization.");
            moveGoal = null;
        }
    }

    static void RecordMove(State before, State after, double goalX, double goalY, string terrainKey, string afterKey = null)
    {
        if ((afterKey != null && afterKey != terrainKey) || !SameScene(before, after, true))
        {
            moveGoal = null;
            Event("move-goal-invalidated", "Observed scene changed while moving; the old future position is not authorized.");
            return;
        }
        ValidateGoal(after, terrainKey);
        int failures = moveGoal == null ? 0 : moveGoal.NoProgress;
        if (moveGoal == null || moveGoal.X != goalX || moveGoal.Y != goalY)
            moveGoal = new MoveGoal { Context = before, TerrainKey = terrainKey, X = goalX, Y = goalY };
        double previous = Math.Abs(goalX - before.X), remaining = Math.Abs(goalX - after.X);
        moveGoal.NoProgress = previous - remaining > 2 ? 0 : Math.Min(2, failures + 1);
        moveGoal.Context = after;
        Event("move-goal-progress", new { targetSlot = after.TargetSlot, goalX = goalX, goalY = goalY,
            observedX = after.X, observedY = after.Y, noProgress = moveGoal.NoProgress, predictedArrival = false });
        if (remaining <= 2 || Math.Sign(goalX - before.X) != Math.Sign(goalX - after.X)) moveGoal = null;
    }

    static ShotPlan LookAhead(State state, AimState aim, ArmorBallistics.Terrain terrain, string terrainKey,
        Stopwatch budget, string stopFile, SearchStats stats)
    {
        ShotPlan best = null;
        // ponytail: beam width two (one supported step per direction), then 24/48px further; <=96px total.
        // Future movement energy is never promised. Each real step is reobserved; no holes, global pathfinder or teleporting.
        var firstSteps = Positions(state, aim, terrain, true, terrainKey, stats).Where(p => p.X != state.X)
            .GroupBy(p => Math.Sign(p.X - state.X)).Select(g => g.OrderByDescending(p => Math.Abs(p.X - state.X)).First()).ToArray();
        int evaluated = 0;
        foreach (ShotPlan first in firstSteps)
        {
            State from = state.Copy();
            from.X = first.X; from.Y = first.Y; from.Slope = (int)Math.Round(first.Slope);
            int direction = Math.Sign(first.X - state.X);
            var goals = new List<int>();
            if (moveGoal != null && moveGoal.Context.TargetSlot == state.TargetSlot && moveGoal.NoProgress < 2 &&
                Math.Sign(moveGoal.X - state.X) == direction) goals.Add((int)moveGoal.X);
            goals.Add((int)first.X + direction * 24); goals.Add((int)first.X + direction * 48);
            foreach (int x in goals.Distinct())
            {
                if (StopRequested(stopFile) || budget.ElapsedMilliseconds >= 1450) return best;
                if (Math.Abs(x - state.X) > 96 || Math.Sign(x - first.X) != direction) continue;
                ShotPlan goal = SupportedPosition(from, aim, terrain, x, stats);
                if (goal == null) continue;
                ShotPlan future = SearchAt(state, aim, terrain, goal.X, goal.Y, goal.Slope, state.TargetX, state.TargetY,
                    Math.Max(6, activeDifficulty.Behavior.AngleStepDegrees), budget, stopFile, ref evaluated, false,
                    Math.Min(1450, budget.ElapsedMilliseconds + 40), 1, terrainKey, stats);
                if (future == null || !future.Shot.Clear || future.Confidence.Percent < 50) continue;
                double score = future.Score + Math.Abs(first.X - state.X) * 0.18 -
                    (moveGoal != null && moveGoal.X == goal.X && moveGoal.Context.TargetSlot == state.TargetSlot ? 4 : 0);
                if (best == null || score < best.Score)
                    best = new ShotPlan { X = first.X, Y = first.Y, Slope = first.Slope, GoalX = goal.X, GoalY = goal.Y,
                        TargetSlot = state.TargetSlot, Facing = future.Facing, Score = score, Confidence = future.Confidence };
            }
        }
        return best;
    }

    static ShotPlan ChooseTactics(State state, AimState aim, ArmorBallistics.Terrain terrain, string stopFile,
        Stopwatch budget, bool allowMove, bool lockedOnly = false, bool fixedAngle = false, int weapon = 1)
    {
        budget.Start();
        try
        {
            string key = TerrainKey(terrain);
            ValidateGoal(state, key);
            int[] targets = lockedOnly ? new[] { state.TargetSlot } : Enumerable.Range(0, 8).Where(slot => Enemy(state, slot)).ToArray();
            var counts = targets.Select(slot => new SearchStats { TargetSlot = slot }).ToArray();
            ShotPlan best = null;
            long end = lockedOnly ? 1600 : 1100;
            for (int index = 0; index < targets.Length; index++)
            {
                if (StopRequested(stopFile) || budget.ElapsedMilliseconds >= end) break;
                State target = ForTarget(state, targets[index]);
                double scale = MemoryFor(target, key, weapon) == null ? 1 : 0.2;
                double tx = Math.Max(0, Math.Min(terrain.Width - 1, target.TargetX + (turnNoise == null ? 0 : turnNoise.EstimateX * scale)));
                double ty = Math.Max(0, Math.Min(terrain.Height - 1, target.TargetY + (turnNoise == null ? 0 : turnNoise.EstimateY * scale)));
                counts[index].TargetEstimateX = tx; counts[index].TargetEstimateY = ty;
                ShotPlan plan = ChoosePlan(target, aim, terrain, tx, ty, stopFile, allowMove, fixedAngle, budget,
                    Math.Min(end, budget.ElapsedMilliseconds + Math.Max(1, (end - budget.ElapsedMilliseconds) / (targets.Length - index))),
                    weapon, key, counts[index]);
                if (BetterShot(plan, best)) best = plan;
            }
            if (weapon == 1 && allowMove && !fixedAngle && (best == null || !best.Shot.Clear))
            {
                ShotPlan goal = null;
                for (int index = 0; index < targets.Length; index++)
                {
                    ShotPlan candidate = LookAhead(ForTarget(state, targets[index]), aim, terrain, key, budget, stopFile, counts[index]);
                    if (candidate != null && (goal == null || candidate.Score < goal.Score)) goal = candidate;
                }
                if (goal != null) best = goal;
            }
            SearchStats selectedStats = best == null ? null : counts.First(c => c.TargetSlot == best.TargetSlot);
            Event("plan", new { scope = "tactical-all-enemies", turn = state.TurnNumber, targets = targets, rejectionCounts = counts,
                evaluated = counts.Sum(c => c.Angles), movementEvaluated = counts.Sum(c => c.MovedAngles),
                milliseconds = budget.ElapsedMilliseconds, targetSlot = best == null ? (int?)null : best.TargetSlot,
                targetName = best == null ? null : state.Room.Names[best.TargetSlot],
                selectedX = best == null ? (double?)null : best.X, gunAngle = best == null || best.MoveOnly ? (int?)null : best.GunAngle,
                clear = best != null && !best.MoveOnly && best.Shot.Clear, goalX = best == null || !best.MoveOnly ? (double?)null : best.GoalX,
                intent = best == null ? "none" : best.MoveOnly ? "movement-only" : best.Shot.Clear ? "direct" : "excavation",
                modelConfidencePercent = best == null ? (double?)null : best.Confidence.Percent,
                confidenceMeaning = ConfidenceMeaning, moveRemainingNativeUnits = aim.MoveRemaining,
                moveRemaining = aim.MoveRemaining, terrainWidth = terrain.Width, terrainHeight = terrain.Height,
                targetEstimateX = selectedStats == null ? (double?)null : selectedStats.TargetEstimateX,
                targetEstimateY = selectedStats == null ? (double?)null : selectedStats.TargetEstimateY,
                legalAngles = new[] { aim.Minimum, aim.Maximum },
                trueAngleBands = new[] { aim.Minimum1, aim.Maximum1, aim.Minimum2, aim.Maximum2 },
                shot2Calibration = shot2.Status, shot2DisabledReason = shot2.DisabledReason, weapon = weapon });
            return best;
        }
        finally { budget.Stop(); }
    }

    static State MoveTo(IntPtr window, double destination, State turn, LabClient.MemoryReader memory,
        LabClient.MemoryReader human, ArmorBallistics.Terrain terrain, string stopFile)
    {
        RequireInputOwnership();
        var watch = Stopwatch.StartNew();
        State state = Stable(memory, human);
        double initialX = state.X;
        int stalled = 0;
        while (!StopRequested(stopFile) && watch.ElapsedMilliseconds < 1800 &&
            movementSpent < activeDifficulty.Behavior.MaxMovePixels && Math.Abs(destination - state.X) > 2)
        {
            CheckTurn(state, turn);
            AimState aim = ReadAim(memory, state);
            if (aim.MoveRemaining <= 0) { Status("Movement budget exhausted; replanning from the actual position."); break; }
            int direction = Math.Sign(destination - state.X), ground;
            if (!MoveClear(state, destination + direction * 8) ||
                !terrain.Walk((int)state.X, (int)state.Y, (int)destination + direction * 8,
                Math.Max(2, aim.Width / 2), aim.Height, out ground))
            {
                Status("Movement stopped: the remaining path lacks verified ground support."); break;
            }
            State before = state;
            try
            {
                LabClient.HoldDirection(window, direction > 0 ? 39 : 37, Math.Abs(destination - state.X) < 8 ? 50 : 100, delegate {
                    if (StopRequested(stopFile)) return false;
                    State current = Stable(memory, human);
                    CheckTurn(current, turn);
                    return movementSpent + Math.Abs(current.X - before.X) < activeDifficulty.Behavior.MaxMovePixels &&
                        Math.Abs(destination - current.X) > 2 && MoveClear(current, destination + direction * 8);
                });
                Thread.Sleep(40);
                state = Stable(memory, human);
                CheckTurn(state, turn);
            }
            catch
            {
                // Unmeasured input must not be replayed with a fresh movement allowance.
                movementSpent = activeDifficulty.Behavior.MaxMovePixels;
                throw;
            }
            movementSpent += Math.Abs(state.X - before.X);
            Event("move-step", new { turn = state.TurnNumber, fromX = before.X, fromY = before.Y,
                targetSlot = state.TargetSlot, targetName = state.TargetName,
                x = state.X, y = state.Y, slope = state.Slope, destinationX = destination, movementSpent = movementSpent });
            ArmorBallistics.Terrain observedTerrain = ReadTerrain(memory, state);
            if (terrain.Width != observedTerrain.Width || terrain.Height != observedTerrain.Height ||
                !terrain.Cells.SequenceEqual(observedTerrain.Cells))
            {
                Status("Terrain changed during movement; stopping for a fresh tactical plan.");
                break;
            }
            terrain = observedTerrain;
            if (Math.Abs(state.Y - before.Y) > 8 || Math.Abs(state.X - initialX) >= activeDifficulty.Behavior.MaxMovePixels + 8) break;
            if (Math.Abs(state.X - before.X) < 0.5)
            {
                if (++stalled >= 2) { Status("Movement is blocked; no repeated walking input will be sent."); break; }
            }
            else stalled = 0;
        }
        if (Math.Abs(state.X - initialX) > 2)
        {
            RecentPositions.Enqueue(initialX);
            while (RecentPositions.Count > 4) RecentPositions.Dequeue();
        }
        return state;
    }

    static State FaceTarget(IntPtr window, State state, State turn, AimState aim,
        ArmorBallistics.Terrain terrain, LabClient.MemoryReader memory, LabClient.MemoryReader human, string stopFile)
    {
        RequireInputOwnership();
        int desired = state.TargetX >= state.X ? 1 : 0;
        if (state.Facing == desired) return state;
        if (aim.MoveRemaining <= 0)
            throw new LabClient.ChargeUnavailableException("No observed native movement energy remains for a facing change.");
        int ground, direction = desired == 1 ? 1 : -1;
        if (!MoveClear(state, state.X + direction * 2) ||
            !terrain.Walk((int)state.X, (int)state.Y, (int)state.X + direction * 2,
            Math.Max(2, aim.Width / 2), aim.Height, out ground))
        {
            for (int distance = 4; distance <= activeDifficulty.Behavior.MaxMovePixels - movementSpent; distance += 4)
            {
                int x = (int)state.X - direction * distance, y, turnY;
                if (!MoveClear(state, x) ||
                    !terrain.Walk((int)state.X, (int)state.Y, x, aim.Width / 2, aim.Height, out y) ||
                    !terrain.Walk(x, y, x + direction * 2, aim.Width / 2, aim.Height, out turnY)) continue;
                Status("Backing away from an edge before changing facing.");
                state = MoveTo(window, x, turn, memory, human, terrain, stopFile);
                terrain = ReadTerrain(memory, state);
                aim = ReadAim(memory, state);
                break;
            }
            if (!MoveClear(state, state.X + direction * 2) ||
                !terrain.Walk((int)state.X, (int)state.Y, (int)state.X + direction * 2,
                aim.Width / 2, aim.Height, out ground))
                throw new LabClient.ChargeUnavailableException("No supported place to face the target was reachable locally.");
        }
        for (int attempt = 0; attempt < 2 && state.Facing != desired; attempt++)
        {
            if (StopRequested(stopFile)) return state;
            CheckTurn(state, turn);
            if (movementSpent >= activeDifficulty.Behavior.MaxMovePixels || ReadAim(memory, state).MoveRemaining <= 0)
                throw new LabClient.ChargeUnavailableException("No movement budget remains for a safe facing change.");
            double beforeX = state.X;
            try
            {
                LabClient.HoldDirection(window, desired == 1 ? 39 : 37, 150, delegate {
                    if (StopRequested(stopFile)) return false;
                    State current = Stable(memory, human);
                    CheckTurn(current, turn);
                    return current.Facing != desired &&
                        movementSpent + Math.Abs(current.X - beforeX) < activeDifficulty.Behavior.MaxMovePixels &&
                        MoveClear(current, current.X + direction * 2);
                });
                Thread.Sleep(50);
                state = Stable(memory, human);
                CheckTurn(state, turn);
            }
            catch { movementSpent = activeDifficulty.Behavior.MaxMovePixels; throw; }
            movementSpent += Math.Abs(state.X - beforeX);
            terrain = ReadTerrain(memory, state);
            if (state.Facing != desired && !terrain.Walk((int)state.X, (int)state.Y, (int)state.X + direction * 2,
                Math.Max(2, aim.Width / 2), aim.Height, out ground))
                throw new LabClient.ChargeUnavailableException("Facing input changed support; no repeated direction input.");
        }
        if (state.Facing != desired) throw new LabClient.ChargeUnavailableException("The native client did not accept the facing change.");
        return state;
    }

    static State AimAt(IntPtr window, int gunAngle, State turn, LabClient.MemoryReader memory,
        LabClient.MemoryReader human, string stopFile, int maximumMilliseconds, int tolerance = 1)
    {
        RequireInputOwnership();
        State state = Stable(memory, human);
        CheckTurn(state, turn);
        AimState aim = ReadAim(memory, state);
        if (!aim.Legal(gunAngle)) throw new LabClient.ChargeUnavailableException("Requested gun angle is outside the actual native limits.");
        int difference = gunAngle - aim.GunAngle;
        if (Math.Abs(difference) <= tolerance || StopRequested(stopFile)) return state;
        bool up = (difference > 0) == (aim.Minimum <= 90);
        int previous = aim.GunAngle;
        var progress = Stopwatch.StartNew();
        bool clamped = false;
        LabClient.HoldDirection(window, up ? 38 : 40, maximumMilliseconds, delegate
        {
            if (StopRequested(stopFile)) return false;
            state = Stable(memory, human);
            CheckTurn(state, turn);
            int actual = ReadAim(memory, state).GunAngle, remaining = gunAngle - actual;
            if (Math.Abs(remaining) <= tolerance || Math.Sign(remaining) != Math.Sign(difference)) return false;
            if (actual != previous) { previous = actual; progress.Restart(); }
            clamped = progress.ElapsedMilliseconds >= 800;
            return !clamped;
        });
        if (clamped) Status("Native aiming limit reached; replanning instead of holding the same key.");
        return Stable(memory, human);
    }

    static void CheckTurn(State state, State expected = null)
    {
        if (expected != null && !SameTurn(state, expected))
            throw new LabClient.ChargeUnavailableException("The native turn changed during planning.");
        if (!state.MyTurn) throw new LabClient.ChargeUnavailableException("The turn state changed.");
        if (state.Charge != 0) throw new InvalidOperationException("Charging is already nonzero; refusing another shot this turn.");
        if (state.Mobile != 0) throw new InvalidDataException(BotName + " must use Armor for this calibrated controller.");
        if (state.Room == null || RosterIssue(state.Room, true, true) != null)
            throw new InvalidDataException("Combat requires a complete, balanced, named native roster.");
        if (state.Room.InputBlocked)
            throw new LabClient.ChargeUnavailableException("Another native dialog owns input.");
        if (state.TargetSlot < 0 || state.Units[state.TargetSlot] == null || !state.Units[state.TargetSlot].Alive)
            throw new LabClient.ChargeUnavailableException("No living opposing-team target is available.");
        if (state.Room.Teams[state.TargetSlot] == state.Room.Teams[state.Slot])
            throw new InvalidDataException("The selected native slot is an ally, not a target.");
        if (expected != null && expected.TargetSlot != state.TargetSlot)
            throw new LabClient.ChargeUnavailableException("The verified living target changed during planning.");
        if (state.X > 5000 || state.Y > 6000 || state.TargetX > 5000 || state.TargetY > 6000)
            throw new LabClient.ChargeUnavailableException("A player is outside the supported battlefield bounds.");
    }

    static bool PassTurn(int botPid, LabClient.MemoryReader memory, LabClient.MemoryReader human,
        State expected, string stopFile, string reason)
    {
        if (StopRequested(stopFile)) return false;
        RequireInputOwnership();
        try
        {
            State current = Stable(memory, human);
            if (!current.MyTurn || current.Room.InputBlocked || current.Mobile != 0 ||
                current.Charge != 0 || !SameTurn(current, expected))
            {
                Event("pass-withheld", "The native turn changed or charging was active.");
                return false;
            }
            IntPtr window = LabClient.Window(botPid);
            LabClient.Focus(window);
            current = Stable(memory, human);
            if (StopRequested(stopFile) || !current.MyTurn || current.Room.InputBlocked || current.Mobile != 0 ||
                current.Charge != 0 || !SameTurn(current, expected))
            {
                Event("pass-withheld", "Native state changed before the pass input.");
                return false;
            }
            LabClient.Key(window, 119, 150, false);
            Event("turn-pass", new { turn = current.TurnNumber, slot = current.Slot, reason = reason });
            Status(BotName + " passed this turn: " + reason);
            return true;
        }
        catch (SnapshotBusyException error) { Event("pass-withheld", error.Message); return false; }
    }

    static State SelectWeapon(IntPtr window, int weapon, State turn, LabClient.MemoryReader memory,
        LabClient.MemoryReader human, string stopFile)
    {
        RequireInputOwnership();
        if (weapon != 1 && (weapon != 2 || !shot2.Available))
            throw new LabClient.ChargeUnavailableException(shot2.DisabledReason + " SS is never permitted.");
        State state = Stable(memory, human);
        CheckTurn(state, turn);
        AimState aim = ReadAim(memory, state);
        if (aim.ShotMode == weapon - 1) return state;
        if (StopRequested(stopFile)) return state;
        if (aim.ShotMode != 0)
        {
            LabClient.Click(window, 28, 550, false, false, 150);
            state = Stable(memory, human); CheckTurn(state, turn);
            if (ReadAim(memory, state).ShotMode != 0)
                throw new LabClient.ChargeUnavailableException("The native client did not confirm Armor S1 selection.");
        }
        if (weapon == 2)
        {
            shot2.Validate();
            if (StopRequested(stopFile)) return state;
            state = Stable(memory, human); CheckTurn(state, turn);
            if (ReadAim(memory, state).ShotMode != 0)
                throw new LabClient.ChargeUnavailableException("S2 selection requires freshly observed S1; no blind Tab cycling.");
            LabClient.Key(window, shot2.SelectionKey.Value, 100, false);
            state = Stable(memory, human); CheckTurn(state, turn);
            if (ReadAim(memory, state).ShotMode != 1)
                throw new LabClient.ChargeUnavailableException("One verified S2 selection was not confirmed natively; no repeated Tab or SS firing.");
        }
        Event("weapon-selected", new { weapon = weapon, nativeMode = ReadAim(memory, state).ShotMode,
            action = "native selection confirmed; reacquire angle limits and trajectory" });
        return state;
    }

    static void RequestedNoise(AimState aim, int solvedPower, TurnNoise noise, bool learned, out int gun, out int power)
    {
        double scale = learned ? 0.2 : 1;
        gun = Math.Max(aim.Minimum, Math.Min(aim.Maximum, (int)Math.Round(aim.GunAngle + noise.Angle * scale)));
        power = Math.Max(40, Math.Min(400, solvedPower + (int)Math.Round(noise.Power * scale)));
    }

    static bool MeetsShot2Policy(Robustness confidence, bool direct)
    {
        return direct && confidence != null && confidence.Safe &&
            confidence.NominalDirect && confidence.Percent >= shot2.MinimumModelConfidencePercent;
    }

    static bool CanUseShot2(Robustness confidence, bool direct)
    {
        return shot2.Available && MeetsShot2Policy(confidence, direct);
    }

    static bool CanChargeGeometry(State planned, State current, State turn, AimState aim, AimState currentAim, int weapon)
    {
        return (weapon == 1 || (weapon == 2 && Shot2Envelope(current, current.X, current.Y, current.Slope, current.Facing, currentAim.GunAngle))) &&
            current.MyTurn && current.Mobile == 0 &&
            SameTurn(current, turn) && SameShotGeometry(planned, current) && Enemy(current, current.TargetSlot) &&
            current.TargetSlot == turn.TargetSlot && currentAim.Legal(currentAim.GunAngle) &&
            currentAim.GunAngle == aim.GunAngle && currentAim.WorldAngle == aim.WorldAngle && currentAim.ShotMode == weapon - 1;
    }

    static TurnAction TakeTurn(int botPid, LabClient.MemoryReader memory, LabClient.MemoryReader human,
        string stopFile, out bool chargeAttempted, State expected = null)
    {
        chargeAttempted = false;
        if (StopRequested(stopFile)) return TurnAction.None;
        RequireInputOwnership();
        State state = Stable(memory, human);
        CheckTurn(state, expected);
        EnsureMatch(state);
        TurnNoise noise = NoiseFor(state, activeDifficulty, AimRandom);
        State turn = state;
        if (StopRequested(stopFile)) return TurnAction.None;
        IntPtr window = LabClient.Window(botPid);
        LabClient.Focus(window);
        state = SelectWeapon(window, 1, turn, memory, human, stopFile);
        AimState aim = ReadAim(memory, state);
        ArmorBallistics.Terrain terrain = ReadTerrain(memory, state);
        var budget = new Stopwatch();
        ShotPlan plan = ChooseTactics(state, aim, terrain, stopFile, budget, true);
        if (plan == null)
            throw new LabClient.ChargeUnavailableException("No safe shot or supported two-hop firing goal for any living enemy; see tactical rejection counts.");
        turn = LockTarget(state, plan.TargetSlot);
        state = Stable(memory, human); CheckTurn(state, turn);
        bool moved = false;
        if (Math.Abs(plan.X - state.X) > 2)
        {
            State before = state;
            string beforeKey = TerrainKey(terrain);
            Status(BotName + (plan.MoveOnly ? " is advancing a supported firing-position goal." : " is repositioning for a better model-robust shot."));
            state = MoveTo(window, plan.X, turn, memory, human, terrain, stopFile);
            moved = Math.Abs(state.X - before.X) > 2;
            terrain = ReadTerrain(memory, state);
            RecordMove(before, state, plan.MoveOnly ? plan.GoalX : plan.X, plan.MoveOnly ? plan.GoalY : plan.Y,
                beforeKey, TerrainKey(terrain));
        }
        if (StopRequested(stopFile)) return TurnAction.None;
        state = FaceTarget(window, state, turn, ReadAim(memory, state), terrain, memory, human, stopFile);
        terrain = ReadTerrain(memory, state);
        state = Stable(memory, human); CheckTurn(state, turn);
        aim = ReadAim(memory, state);
        plan = ChooseTactics(state, aim, terrain, stopFile, budget, false, true);
        if (plan == null)
        {
            if (moved) return TurnAction.Repositioned;
            throw new LabClient.ChargeUnavailableException("The actual observed position/facing has no safe shot; no predicted move was treated as achieved.");
        }
        int weapon = CanUseShot2(plan.Confidence, plan.Shot.Clear) &&
            Shot2Envelope(state, state.X, state.Y, state.Slope, state.Facing) ? 2 : 1;
        if (!shot2.Available)
            Event("shot2-unavailable", new { status = shot2.Status, reason = shot2.DisabledReason });
        for (int acquisition = 0; acquisition < 2; acquisition++)
        {
            if (StopRequested(stopFile)) return TurnAction.None;
            state = SelectWeapon(window, weapon, turn, memory, human, stopFile);
            aim = ReadAim(memory, state);
            if (weapon != 1 || acquisition != 0)
                plan = ChooseTactics(state, aim, terrain, stopFile, budget, false, true, false, weapon);
            if (plan != null)
            {
                state = AimAt(window, plan.GunAngle, turn, memory, human, stopFile, activeDifficulty.Behavior.MaxAngleAdjustmentMs);
                terrain = ReadTerrain(memory, state);
                state = Stable(memory, human); CheckTurn(state, turn);
                aim = ReadAim(memory, state);
                plan = ChooseTactics(state, aim, terrain, stopFile, budget, false, true, true, weapon);
            }
            if (plan == null)
            {
                if (weapon == 2) { Event("shot2-withheld", "Native S2 angle/physics reacquisition was not high-confidence; returning to S1."); weapon = 1; continue; }
                if (moved) return TurnAction.Repositioned;
                throw new LabClient.ChargeUnavailableException("No safe shot at the actual native angle, or shared tactical budget exhausted.");
            }
            int solvedAngle = aim.GunAngle, noisyGun, power;
            RequestedNoise(aim, plan.Shot.Power, noise, plan.Learned, out noisyGun, out power);
            if (noisyGun != aim.GunAngle)
                state = AimAt(window, noisyGun, turn, memory, human, stopFile, 700, 0);
            terrain = ReadTerrain(memory, state);
            state = Stable(memory, human); CheckTurn(state, turn);
            aim = ReadAim(memory, state);
            if (!aim.Legal(aim.GunAngle) || aim.ShotMode != weapon - 1)
                throw new LabClient.ChargeUnavailableException("The final native angle or weapon mode changed; SS is never authorized.");
            if (plan.Learned && MemoryFor(state, TerrainKey(terrain), weapon) == null)
                throw new LabClient.ChargeUnavailableException("The observed-shot scene lock changed during acquisition; reacquisition is required.");
            // ponytail: freeze power after intentional noise; safe near misses remain imperfect direct attempts.
            Robustness actual = AssessShot(state, aim, terrain, state.X, state.Y, state.Slope, state.Facing,
                aim.GunAngle, power, weapon);
            if (weapon == 2 && !CanUseShot2(actual, plan.Shot.Clear))
            {
                Event("shot2-withheld", new { reason = "Actual noisy S2 is not a safe >=80% model-estimate direct shot.",
                    modelConfidencePercent = actual.Percent, confidenceMeaning = ConfidenceMeaning });
                weapon = 1; continue;
            }
            bool direct = plan.Shot.Clear;
            if (!actual.Safe || (weapon == 1 && !UsableShot(state, actual.Nominal, state.X, state.Y, state.Slope,
                state.Facing, direct)))
                throw new LabClient.ChargeUnavailableException("Actual noisy shot/uncertainty envelope is unsafe, off-map, or not useful; replanning keeps this turn's sampled noise.");
            string intent = direct ? "direct" : "excavation";
            if (StopRequested(stopFile)) return TurnAction.None;
            Event(direct ? "shot-attempt" : "excavation-attempt", new { intent = intent, weapon = weapon,
                turn = state.TurnNumber, slot = state.Slot, targetSlot = state.TargetSlot, targetName = state.TargetName,
                angle = state.Angle, power = power, modelConfidencePercent = actual.Percent, confidenceMeaning = ConfidenceMeaning,
                modelSamples = actual.Samples, safeSamples = actual.SafeSamples, directSamples = actual.DirectSamples });
            chargeAttempted = true;
            State releaseState = state;
            var result = LabClient.Charge(window, power, delegate {
                if (StopRequested(stopFile)) return false;
                State current = Stable(memory, human);
                if (!current.MyTurn || !SameTurn(current, turn) || !SameShotGeometry(state, current)) return false;
                if (!CanChargeGeometry(state, current, turn, aim, ReadAim(memory, current), weapon)) return false;
                releaseState = current;
                return true;
            });
            ObserveCharge(power, result.ObservedPower);
            pendingImpact = new PendingImpact { Turn = releaseState, Before = terrain, Shot = actual.Nominal, DirectAttempt = direct,
                WorldAngle = aim.WorldAngle, GunAngle = aim.GunAngle, Weapon = weapon, ObservedPower = result.ObservedPower };
            Event("shot", new {
                intent = intent, weapon = weapon, predictedDirect = actual.NominalDirect, predictedTerrainImpact = actual.Nominal.TerrainImpact,
                predictedImpactKind = actual.Nominal.End.ToString(), predictedHitSlot = actual.Nominal.HitSlot,
                modelConfidencePercent = actual.Percent, confidenceMeaning = ConfidenceMeaning, learnedShot = plan.Learned,
                difficulty = activeDifficulty.Name, solvedAngle = solvedAngle, requestedAimNoise = noise.Angle,
                requestedAimError = noise.Angle * (plan.Learned ? 0.2 : 1),
                targetEstimateErrorX = noise.EstimateX * (plan.Learned ? 0.2 : 1),
                targetEstimateErrorY = noise.EstimateY * (plan.Learned ? 0.2 : 1),
                requestedPowerNoise = noise.Power, noiseScale = plan.Learned ? 0.2 : 1,
                gunAngle = aim.GunAngle, worldAngle = aim.WorldAngle,
                turn = state.TurnNumber, slot = state.Slot, targetSlot = state.TargetSlot, targetName = state.TargetName,
                angle = state.Angle, facing = state.Facing, x = state.X, y = state.Y, targetX = state.TargetX, targetY = state.TargetY,
                wind = state.Wind, direction = state.WindDirection, power = power, predictedError = actual.Nominal.Error,
                predictedImpactX = actual.Nominal.LandingX, predictedImpactY = actual.Nominal.LandingY, observedPower = result.ObservedPower,
                chargeUncertaintyPowerUnits = chargeUncertainty, milliseconds = result.Milliseconds, samples = result.Samples,
                meanSampleMilliseconds = result.MeanSampleMilliseconds, confirmation = "single-pre-release-frame-and-release-only"
            });
            Console.WriteLine("{0} S{1} {2} charge/release observed; hit unconfirmed.{3}", BotName, weapon, intent,
                showModelConfidence ? " Model robustness " + actual.Percent.ToString("F0") + "% (not calibrated hit probability)." : "");
            return TurnAction.Shot;
        }
        throw new LabClient.ChargeUnavailableException("Verified weapon reacquisition exhausted; no shot sent.");
    }

    static void RestoreHuman(int humanPid, int botPid)
    {
        RequireInputOwnership();
        uint owner;
        LabClient.GetWindowThreadProcessId(LabClient.GetForegroundWindow(), out owner);
        if (owner == botPid) LabClient.Focus(LabClient.Window(humanPid));
    }

    static int Run(int? humanPid, int botPid)
    {
        if (humanPid.HasValue) LabClient.ValidateClient(humanPid.Value);
        LabClient.ValidateClient(botPid);
        botAccount = LabClient.BotAccountName;
        if (!TeamNames.Skip(1).Contains(botAccount))
            throw new InvalidDataException("Unsupported controller account: " + botAccount + ".");
        var profiles = Profiles(botAccount);
        activeDifficulty = profiles.Tiers[profiles.Assignments[botAccount]];
        shot2 = profiles.ArmorShot2; showModelConfidence = profiles.ShowModelConfidence;
        inputFaultFile = GuestInputFaultPath(LabClient.Root);
        inputFaultObserved = false;
        string stopFile = Path.Combine(LabClient.Root, "bot.stop");
        int exitCode = 0;
        using (var singleton = new Mutex(false, SingletonName(LabClient.Root)))
        using (var guestInput = new Mutex(false, GuestInputMutex))
        {
            bool acquired;
            try { acquired = singleton.WaitOne(0); }
            catch (AbandonedMutexException)
            {
                acquired = true;
                Console.Error.WriteLine("Recovering the controller lock after an unexpected previous exit.");
            }
            if (!acquired) throw new InvalidOperationException("A controller is already running for " + BotName + " at this instance root.");
            try
            {
                if (humanPid.HasValue && File.Exists(stopFile)) File.Delete(stopFile);
                using (var file = new FileStream(Path.Combine(LabClient.Root, "logs", "bot-events.jsonl"),
                    FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
                using (log = new StreamWriter(file) { AutoFlush = true })
                using (var memory = new LabClient.MemoryReader(botPid))
                using (var human = humanPid.HasValue ? new LabClient.MemoryReader(humanPid.Value) : null)
                using (var botProcess = Process.GetProcessById(botPid))
                using (var humanProcess = humanPid.HasValue ? Process.GetProcessById(humanPid.Value) : null)
                {
                    var runtime = Stopwatch.StartNew();
                    bool sawOwnTurn = false;
                    string turnOutcome = null, waitReason = "not-attempted";
                    try
                    {
                        string controllerMode = humanPid.HasValue ? "legacy" : "standalone";
                        Event("profile", new {
                            controllerMode = controllerMode,
                            difficulty = activeDifficulty.Name, gear = activeDifficulty.Gear.Name,
                            thinkDelayMs = activeDifficulty.Behavior.ThinkDelayMs,
                            aimErrorDegrees = activeDifficulty.Behavior.AimErrorDegrees,
                            powerErrorUnits = activeDifficulty.Behavior.PowerErrorUnits,
                            confidenceMeaning = ConfidenceMeaning, shot2Calibration = shot2.Status,
                            shot2Available = shot2.Available, shot2ModelThreshold = shot2.MinimumModelConfidencePercent,
                            shot2DisabledReason = shot2.DisabledReason
                        });
                        Console.WriteLine("{0} ({1}): {2} / {3}.", BotName, controllerMode, activeDifficulty.Name, activeDifficulty.Gear.Name);
                        Console.WriteLine("{0} Eventual policy: >=80% model-robustness DIRECT shots only, NOT a calibrated hit probability.",
                            shot2.DisabledReason);
                        if (!SetConsoleCtrlHandler(ExitHandler, true)) throw new Win32Exception(Marshal.GetLastWin32Error());
                        Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs e) {
                            RequestStop(e.SpecialKey == ConsoleSpecialKey.ControlC ? "console-ctrl-c" : "console-ctrl-break");
                            e.Cancel = true;
                        };
                        using (var self = Process.GetCurrentProcess())
                        {
                            var record = new System.Collections.Generic.Dictionary<string, object> {
                                { "ProcessId", self.Id }, { "StartedUtcTicks", self.StartTime.ToUniversalTime().Ticks },
                                { "BotProcessId", botPid }, { "Executable", self.MainModule.FileName },
                                { "Mode", controllerMode }, { "BotAccount", BotName }, { "Root", LabClient.Root }
                            };
                            if (humanPid.HasValue) record["HumanProcessId"] = humanPid.Value;
                            File.WriteAllText(Path.Combine(LabClient.Root, "bot-process.json"), Json.Serialize(record));
                        }
                        bool armed = memory.Int32(0x0087053C) != 11;
                        var turns = new TurnTracker();
                        turns.Reset(armed);
                        int attempts = 0;
                        string roomKey = null;
                        RoomRequest roomRequest = null;
                        DateTime roomSince = DateTime.MinValue;
                        DateTime ownSince = DateTime.MinValue, nextAttempt = DateTime.MinValue;
                        while (!StopRequested(stopFile))
                        {
                            if (ClientExited(botProcess, humanProcess)) break;
                            ObserveImpact(memory);
                            State state;
                            try { state = Stable(memory, human); }
                            catch (SnapshotBusyException error)
                            {
                                waitReason = "synchronized-client-state-unavailable";
                                Status("Waiting for a synchronized client state: " + error.Message);
                                Thread.Sleep(100);
                                continue;
                            }
                            catch (InvalidDataException error)
                            {
                                waitReason = "unsupported-native-state";
                                Status("Paused: " + error.Message);
                                Thread.Sleep(250);
                                continue;
                            }
                            if (state.Mode != 11)
                            {
                                ReportSkippedTurn(sawOwnTurn, turnOutcome, "left-match; last wait: " + waitReason);
                                armed = true; turnOutcome = null; attempts = 0; sawOwnTurn = false;
                                RecentPositions.Clear();
                                pendingImpact = null; repeatedMisses = 0;
                                excavationTarget = null; failedExcavations = 0;
                                ResetTactics(null);
                                turns.Reset(true);
                                ownSince = DateTime.MinValue; nextAttempt = DateTime.MinValue;
                                movementSpent = 0;
                                if (state.Mode == 9)
                                {
                                    bool roomFocused = false;
                                    try
                                    {
                                        RoomState room = ReadRoom(memory, 9);
                                        if (room.SelfName != BotName)
                                            throw new InvalidDataException("Native self " + room.SelfName + " does not identify instance " + BotName + ".");
                                        if (room.Key != roomKey)
                                        {
                                            roomKey = room.Key; roomSince = DateTime.UtcNow;
                                            Event("room-state", new { room.RoomId, room.Capacity, room.GameType, room.SelfSlot, room.SelfName, room.MasterSlot,
                                                room.PlayerSlot, room.Occupied, room.Names, room.States, room.Teams });
                                        }
                                        if (roomRequest != null && !roomRequest.Pending(room))
                                        {
                                            Event("room-request-settled", new { action = roomRequest.Action.ToString(), room.SelfName });
                                            roomRequest = null;
                                        }
                                        RoomInput action = RoomAction(room);
                                        bool peerReady = human == null;
                                        if (human != null && PeerInMode(human, 9))
                                        {
                                            RoomState peer = ReadRoom(human, 9);
                                            peerReady = peer.SelfName == "Player" && SameRoom(room, peer);
                                        }
                                        if (action != RoomInput.None && roomRequest == null && peerReady &&
                                            (DateTime.UtcNow - roomSince).TotalSeconds >= 1 &&
                                            GameHasFocus(humanPid, botPid, room))
                                        {
                                            bool abandoned;
                                            if (!TryAcquireInput(guestInput, out abandoned))
                                            {
                                                Status(BotName + " is waiting for exclusive guest input; no focus or keys changed.");
                                                Thread.Sleep(100); continue;
                                            }
                                            if (abandoned)
                                            {
                                                Event("guest-input-abandoned", inputFaultFile == null ?
                                                    "Room input withheld; no foreign key releases. Waiting for a fresh settled roster." :
                                                    "Room input withheld; sticky guest fault requires parent/manual recovery.");
                                                roomSince = DateTime.UtcNow;
                                                continue;
                                            }
                                            if (!InputsIdle())
                                            {
                                                Status("Paused: an input key/button is already held; no foreign key releases.");
                                                roomSince = DateTime.UtcNow;
                                                continue;
                                            }
                                            RoomState fresh = ReadRoom(memory, 9);
                                            if (fresh.Key != roomKey || fresh.SelfName != BotName || RoomAction(fresh) != action ||
                                                !GameHasFocus(humanPid, botPid, fresh)) continue;
                                            IntPtr window = LabClient.Window(botPid);
                                            roomFocused = true;
                                            LabClient.Focus(window);
                                            fresh = ReadRoom(memory, 9);
                                            if (fresh.Key != roomKey || fresh.SelfName != BotName || RoomAction(fresh) != action) continue;
                                            if (StopRequested(stopFile)) break;
                                            Status("Requesting " + BotName + " " + action + "; waiting for native confirmation.");
                                            Event(action == RoomInput.Start ? "master-start-attempt" :
                                                action == RoomInput.Ready ? "ready-click-attempt" :
                                                action == RoomInput.Unready ? "unready-click-attempt" : "team-switch-attempt",
                                                new { action = action.ToString(), room.RoomId, room.Capacity,
                                                room.SelfSlot, room.SelfName, room.MasterSlot, room.PlayerSlot,
                                                desiredTeam = DesiredTeam(room, room.SelfName) });
                                            // Record BEFORE input: a failed/interrupted toggle is not safe to resend.
                                            roomRequest = new RoomRequest { Before = fresh, Action = action };
                                            RequireInputOwnership();
                                            // Team control BF -> 005102B5 emits 3210 with 1-selfTeam.
                                            LabClient.Click(window, action == RoomInput.SwitchTeam ? 480 : 756,
                                                action == RoomInput.SwitchTeam ? 180 : 568, false, false, humanPid.HasValue ? 60 : 150);
                                        }
                                        else if (roomRequest != null && RosterIssue(room, true, false) == null)
                                            Status((roomRequest.Watch.ElapsedMilliseconds > 5000 ? "Paused: " : "Waiting: ") +
                                                BotName + " " + roomRequest.Action + " needs native confirmation; no repeated toggle will be sent.");
                                        else Status(RoomWait(room));
                                    }
                                    catch (SnapshotBusyException) { Status("Waiting for a synchronized native room roster."); }
                                    catch (InvalidDataException error) { Status("Paused: " + error.Message); }
                                    catch (InvalidOperationException error) { Status("Room input withheld: " + error.Message); }
                                    finally
                                    {
                                        EndInput(guestInput, delegate {
                                            LabClient.ReleaseOwnedInput();
                                            if (roomFocused && humanPid.HasValue && !inputFaultObserved) RestoreHuman(humanPid.Value, botPid);
                                        });
                                    }
                                }
                                else
                                {
                                    roomKey = null; roomRequest = null;
                                    Status("Waiting for an active match (client mode " + state.Mode + ").");
                                }
                                Thread.Sleep(200);
                                continue;
                            }
                            roomKey = null; roomRequest = null;
                            try
                            {
                                if (turns.Observe(state.Battle, state.TurnNumber, state.ActiveSlot))
                                {
                                    ReportSkippedTurn(sawOwnTurn, turnOutcome, "native turn advanced; last wait: " + waitReason);
                                    armed = turns.CanAct; turnOutcome = null; attempts = 0; sawOwnTurn = false;
                                    ownSince = DateTime.MinValue; nextAttempt = DateTime.MinValue;
                                    movementSpent = 0;
                                    EnsureMatch(state);
                                    NoiseFor(state, activeDifficulty, AimRandom);
                                    Event("native-turn", new { turn = state.TurnNumber, actor = state.ActiveSlot,
                                        self = state.Slot, battle = state.Battle, armed = armed });
                                }
                            }
                            catch (SnapshotBusyException error)
                            {
                                Status(error.Message); Thread.Sleep(50); continue;
                            }
                            if (state.MyTurn && !sawOwnTurn)
                            {
                                sawOwnTurn = true;
                                waitReason = "not-attempted";
                                Event("turn-observed", new { turn = state.TurnNumber, slot = state.Slot, targetSlot = state.TargetSlot,
                                    targetName = state.TargetName, armed = armed });
                            }
                            if (!PeerInMode(human, 11))
                            {
                                waitReason = "human-client-not-in-match";
                                Status("Waiting for the human client to be in the match.");
                                Thread.Sleep(150);
                                continue;
                            }
                            if (!state.MyTurn)
                            {
                                if (!state.SelfAlive)
                                {
                                    waitReason = "self-is-dead";
                                    Status(BotName + " is natively dead; no movement, pass or shot input.");
                                }
                                else if (OtherTurn(state))
                                {
                                    Status(state.Room.Names[state.ActiveSlot] + "'s turn; " + BotName + " is waiting.");
                                }
                                else
                                {
                                    waitReason = "own-turn-not-actionable";
                                    Status(turnOutcome == null ?
                                        "Bot turn deferred: own turn is not actionable." :
                                        BotName + " is waiting for the next native turn; no repeat shot.");
                                }
                                Thread.Sleep(100);
                                continue;
                            }
                            if (!armed)
                            {
                                if (turnOutcome == null)
                                {
                                    turnOutcome = "skipped";
                                    Event("turn-skipped", new { reason = "attached-mid-turn" });
                                }
                                Status("Bot turn skipped: attached mid-turn; waiting for the next complete bot turn.");
                                Thread.Sleep(100);
                                continue;
                            }
                            if (turnOutcome != null)
                            {
                                Status(turnOutcome == "shot-released" ?
                                    BotName + " charge/release observed; waiting for the turn to finish." :
                                    BotName + " turn " + turnOutcome + "; no further input this turn.");
                                Thread.Sleep(100);
                                continue;
                            }
                            if (state.Mobile != 0)
                            {
                                waitReason = "unsupported-mobile";
                                Status("Paused: " + BotName + " must use Armor; no input.");
                                Thread.Sleep(250); continue;
                            }
                            if (state.Room.InputBlocked)
                            {
                                waitReason = "native-dialog-owns-input";
                                Status("Paused: a native dialog owns input; no movement, aim or pass.");
                                Thread.Sleep(250); continue;
                            }
                            if (!GameHasFocus(humanPid, botPid, state.Room))
                            {
                                waitReason = "owned-client-not-foreground";
                                Status("Bot turn deferred while another application is active.");
                                Thread.Sleep(150);
                                continue;
                            }
                            if (ownSince == DateTime.MinValue) ownSince = DateTime.UtcNow;
                            if ((DateTime.UtcNow - ownSince).TotalMilliseconds < activeDifficulty.Behavior.ThinkDelayMs || DateTime.UtcNow < nextAttempt)
                            {
                                if (DateTime.UtcNow >= nextAttempt) waitReason = "difficulty-think-delay";
                                Status(BotName + " is aiming.");
                                Thread.Sleep(50);
                                continue;
                            }
                            bool chargeAttempted = false;
                            bool turnFocused = false;
                            try
                            {
                                bool abandoned;
                                if (!TryAcquireInput(guestInput, out abandoned))
                                {
                                    waitReason = "guest-input-owned-by-another-controller-or-coordinator";
                                    Status(BotName + " is waiting for exclusive guest input; no focus or keys changed.");
                                    Thread.Sleep(100); continue;
                                }
                                if (abandoned)
                                {
                                    Event("guest-input-abandoned", "This turn is skipped; no foreign key releases.");
                                    turnOutcome = "abandoned";
                                    AbandonTurn("abandoned-guest-input-owner", false);
                                    continue;
                                }
                                State fresh = Stable(memory, human);
                                if (!SameTurn(state, fresh) || !fresh.MyTurn)
                                {
                                    waitReason = "native-turn-changed-while-waiting-for-input";
                                    continue;
                                }
                                if (!InputsIdle() || !GameHasFocus(humanPid, botPid, fresh.Room))
                                {
                                    waitReason = "input-already-held-or-foreground-not-a-verified-room-peer";
                                    Status("Paused: " + waitReason + "; no focus or foreign key releases.");
                                    nextAttempt = DateTime.UtcNow.AddMilliseconds(250);
                                    continue;
                                }
                                state = fresh;
                                turnFocused = true;
                                Event("turn-attempt", new { turn = state.TurnNumber, slot = state.Slot,
                                    targetSlot = state.TargetSlot, targetName = state.TargetName });
                                if (state.TargetSlot < 0)
                                    turnOutcome = PassTurn(botPid, memory, human, state, stopFile,
                                        "No living opposing-team target.") ? "passed" : "abandoned";
                                else
                                {
                                    TurnAction action = TakeTurn(botPid, memory, human, stopFile, out chargeAttempted, state);
                                    if (action == TurnAction.Shot) turnOutcome = "shot-released";
                                    else if (action == TurnAction.Repositioned)
                                        turnOutcome = PassTurn(botPid, memory, human, state, stopFile,
                                            "Observed supported movement toward a revalidated firing goal; no shot available yet.") ? "repositioned-and-passed" : "abandoned";
                                    else
                                    {
                                        turnOutcome = "abandoned";
                                        AbandonTurn(stopReason ?? "stopped-before-charge", chargeAttempted);
                                    }
                                }
                            }
                            catch (SnapshotBusyException)
                            {
                                waitReason = "client-state-changed-during-aiming";
                                if (CanRetryShot(chargeAttempted, 0) && !StopRequested(stopFile))
                                {
                                    Event("shot-deferred", waitReason);
                                    Status("Shot deferred: " + waitReason);
                                    nextAttempt = DateTime.UtcNow.AddMilliseconds(250);
                                }
                                else
                                {
                                    turnOutcome = "abandoned";
                                    AbandonTurn(waitReason, chargeAttempted);
                                }
                            }
                            catch (LabClient.ChargeUnavailableException error)
                            {
                                waitReason = error.Message;
                                attempts++;
                                if (CanRetryShot(chargeAttempted, attempts) && !StopRequested(stopFile))
                                {
                                    Event("shot-deferred", error.Message);
                                    Status("Shot deferred before charging: " + error.Message);
                                    nextAttempt = DateTime.UtcNow.AddMilliseconds(1000);
                                }
                                else
                                {
                                    if (!chargeAttempted && PassTurn(botPid, memory, human, state, stopFile, error.Message))
                                        turnOutcome = "passed";
                                    else
                                    {
                                        turnOutcome = "abandoned";
                                        AbandonTurn(error.Message, chargeAttempted);
                                    }
                                }
                            }
                            catch (InvalidOperationException error)
                            {
                                Event("input-interrupted", error.Message);
                                turnOutcome = "abandoned";
                                AbandonTurn(error.Message, chargeAttempted);
                            }
                            catch (InvalidDataException error)
                            {
                                turnOutcome = "abandoned";
                                AbandonTurn("Paused: " + error.Message, chargeAttempted);
                            }
                            catch (Exception error)
                            {
                                turnOutcome = "abandoned";
                                AbandonTurn(error.Message, chargeAttempted);
                                throw;
                            }
                            finally
                            {
                                EndInput(guestInput, delegate {
                                    LabClient.ReleaseOwnedInput();
                                    if (turnFocused && humanPid.HasValue && !inputFaultObserved) RestoreHuman(humanPid.Value, botPid);
                                });
                            }
                            Thread.Sleep(100);
                        }
                    }
                    catch (Exception error)
                    {
                        if ((error is Win32Exception || error is InvalidOperationException || error is ArgumentException) &&
                            ClientExited(botProcess, humanProcess))
                            Event("client-exit-during-read-or-input", error.Message);
                        else
                        {
                            exitCode = 1;
                            RequestStop("error");
                            Event("error", new { type = error.GetType().Name, message = error.Message });
                            Console.Error.WriteLine(error.Message);
                        }
                    }
                    finally
                    {
                        if (stopReason == null) RequestStop("loop-ended");
                        ReportSkippedTurn(sawOwnTurn, turnOutcome, "controller-stopping (" + stopReason + "); last wait: " + waitReason);
                        Status(BotName + " controller stopped (" + stopReason + ").");
                        Event("stopped", new { seconds = runtime.Elapsed.TotalSeconds, reason = stopReason, exitCode = exitCode });
                    }
                }
            }
            finally
            {
                SetConsoleCtrlHandler(ExitHandler, false);
                singleton.ReleaseMutex();
            }
        }
        return exitCode;
    }

    static void ParseArguments(string[] args, out int? humanPid, out int botPid)
    {
        const string usage = "Usage: bot-controller.exe <human-pid> <bot-pid> | bot-controller.exe --standalone <bot-pid> | bot-controller.exe --self-check";
        humanPid = null;
        botPid = 0;
        if (args.Length != 2 || !Int32.TryParse(args[1], out botPid) || botPid <= 0)
            throw new ArgumentException(usage);
        if (args[0] == "--standalone") return;
        int parsedHuman;
        if (!Int32.TryParse(args[0], out parsedHuman) || parsedHuman <= 0 || parsedHuman == botPid)
            throw new ArgumentException(usage);
        humanPid = parsedHuman;
    }

    static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    static RoomState SelfCheckRoom(int capacity, int selfIndex = 1, int masterIndex = 0,
        int[] slots = null, int playerTeam = 0)
    {
        string[] names = capacity == 4 ? TeamNames : DuelNames;
        slots = slots ?? Enumerable.Range(0, names.Length).ToArray();
        var bytes = new byte[0x1E5];
        for (int index = 0; index < names.Length; index++)
        {
            Encoding.ASCII.GetBytes(names[index]).CopyTo(bytes, slots[index] * 20);
            bytes[0x1DD + slots[index]] = 1;
            bytes[0x1D5 + slots[index]] = (byte)(index == 0 || index == 2 ? playerTeam : 1 - playerTeam);
        }
        RoomState room = ParseRoom(slots[selfIndex], slots[masterIndex], capacity, 0, bytes);
        room.Game = 0x10000; room.RoomId = 37;
        return room;
    }

    static UnitState[] SelfCheckUnits(RoomState room)
    {
        return Enumerable.Range(0, 8).Select(slot => room.States[slot] == 0 ? null :
            new UnitState { Pointer = (uint)(0x20000 + slot * 0x1000), Slot = slot,
                Name = room.Names[slot], Team = room.Teams[slot], Alive = true,
                Health = 1000, MaximumHealth = 1000, X = 100 + slot * 200, Y = 500, Width = 24, Height = 48 }).ToArray();
    }

    static State SelfCheckState(RoomState room)
    {
        room.Mode = 11;
        for (int slot = 0; slot < 8; slot++) if (room.States[slot] != 0) room.States[slot] = 4;
        UnitState[] units = SelfCheckUnits(room);
        int target = ResolveTargetSlot(room, units, room.SelfSlot);
        return new State { Room = room, Units = units, Mode = 11, Game = room.Game, Battle = 0x90000,
            Slot = room.SelfSlot, ActiveSlot = room.SelfSlot, Unit = units[room.SelfSlot].Pointer,
            Active = units[room.SelfSlot].Pointer, TurnNumber = 10, Turn = true, SelfAlive = true,
            TargetSlot = target, TargetName = room.Names[target], X = units[room.SelfSlot].X, Y = units[room.SelfSlot].Y,
            TargetX = units[target].X, TargetY = units[target].Y - units[target].Height / 2.0, Facing = 1 };
    }

    static void RosterSelfCheck()
    {
        var native = new byte[0x1E5];
        Encoding.ASCII.GetBytes("Player").CopyTo(native, 0);
        Encoding.ASCII.GetBytes("BotOne").CopyTo(native, 20);
        native[0x1DD] = native[0x1DE] = native[0x1D6] = 1;
        RoomState incomplete = ParseRoom(0, 0, 4, 0, native);
        Check(incomplete.SelfName == "Player" && incomplete.Capacity == 4 && incomplete.Occupied == 2 &&
            RosterIssue(incomplete, true, true) != null &&
            ParseRoom(1, 0, 4, 2u << 18, native).GameType == 2, "Native capacity/options were replaced by roster guesses.");
        native[0x1DE] = 5;
        bool badState = false;
        try { ParseRoom(1, 0, 2, 0, native); } catch (InvalidDataException) { badState = true; }
        Check(badState, "Unknown native occupancy/ready values were accepted.");
        native[0x1DE] = 1; native[20] = 255;
        bool badName = false;
        try { ParseRoom(1, 0, 2, 0, native); } catch (InvalidDataException) { badName = true; }
        Check(badName, "Unknown native account-name encoding was accepted.");
        for (int bot = 0; bot < 8; bot++)
            for (int player = 0; player < 8; player++)
            {
                if (bot == player) continue;
                RoomState room = SelfCheckRoom(2, slots: new[] { player, bot });
                Check(room.Capacity == 2 && room.Occupied == 2 && room.Duel && room.SelfName == "BotOne" &&
                    RoomAction(room) == RoomInput.Ready, "A verified two-slot roster cannot Ready.");
                Check(ResolveTargetSlot(room, SelfCheckUnits(room), player) == player &&
                    ResolveTargetSlot(room, SelfCheckUnits(room), bot) == player, "Reassigned 1v1 slots lost Player.");
                room.ReadyRequested = true;
                Check(RoomAction(room) == RoomInput.None, "Pending Ready was toggled off.");
                room.MasterSlot = bot;
                Check(RoomAction(room) == RoomInput.None, "Master started before Player Ready.");
                room.States[player] = 3;
                Check(RoomAction(room) == RoomInput.Start, "Verified legacy bot master cannot Start.");
                room.StartBlocked = true;
                Check(RoomAction(room) == RoomInput.None, "Native start eligibility was ignored.");
                room = SelfCheckRoom(2, 0, slots: new[] { player, bot });
                Check(room.SelfName == "Player" && room.PlayerSlot == player && RoomAction(room) == RoomInput.None,
                    "Read-only host diagnostics automated Player or required a bot self slot.");
            }
        foreach (int capacity in new[] { 2, 4 })
            foreach (int playerTeam in new[] { 0, 1 })
                foreach (int[] slots in capacity == 2 ? new[] { new[] { 7, 2 } } :
                    new[] { new[] { 0, 1, 2, 3 }, new[] { 7, 4, 0, 2 } })
                    for (int index = 1; index < slots.Length; index++)
                    {
                        RoomState room = SelfCheckRoom(capacity, index, slots: slots, playerTeam: playerTeam);
                        Check(RosterIssue(room, true, true) == null && RoomAction(room) == RoomInput.Ready,
                            "A full balanced named team roster cannot Ready.");
                        State state = SelfCheckState(room);
                        foreach (int active in slots)
                        {
                            int target = ResolveTargetSlot(room, state.Units, active);
                            Check(target >= 0 && room.Teams[target] != room.Teams[room.SelfSlot] && state.Units[target].Alive,
                                "An active teammate/opponent slot was rejected or selected as an ally target.");
                        }
                        int firstEnemy = state.TargetSlot;
                        state.Units[firstEnemy].Alive = Living(1, 0);
                        int other = ResolveTargetSlot(room, state.Units, slots[0]);
                        Check(capacity == 2 ? other == -1 : other >= 0 && other != firstEnemy,
                            "Dead opponents were selected instead of a living enemy/no-target result.");
                        foreach (UnitState unit in state.Units)
                            if (unit != null && room.Teams[unit.Slot] != room.Teams[room.SelfSlot]) unit.Alive = false;
                        Check(ResolveTargetSlot(room, state.Units, room.SelfSlot) == -1, "An all-dead enemy team supplied a target.");
                        state.Units[room.SelfSlot].Alive = false; state.SelfAlive = false;
                        Check(!state.MyTurn && ResolveTargetSlot(room, state.Units, room.SelfSlot) == -1,
                            "A dead bot was authorized to act.");
                    }
        foreach (int capacity in new[] { 0, 1, 3, 6, 8 })
        {
            RoomState room = SelfCheckRoom(capacity);
            Check(room.Capacity == capacity && room.Occupied == 2 && RoomAction(room) == RoomInput.None &&
                RosterIssue(room, true, true).Contains("capacity"), "Capacity was inferred from occupancy or silently reduced.");
        }
        for (int kind = 0; kind < 7; kind++)
        {
            RoomState room = SelfCheckRoom(4);
            if (kind == 0) room.States[3] = 0;
            if (kind == 1) room.Names[3] = "Stranger";
            if (kind == 2) room.Names[3] = "BotOne";
            if (kind == 3) room.Teams[3] = 255;
            if (kind == 4) room.GameType = 1;
            if (kind == 5) room.GameType = 2;
            if (kind == 6) room.GameType = 3;
            Check(RoomAction(room) == RoomInput.None && RosterIssue(room, true, true) != null,
                "An incomplete/unknown/unsupported roster can issue room input.");
            bool rejected = false;
            try { ResolveTargetSlot(room, SelfCheckUnits(room), room.SelfSlot); }
            catch (InvalidDataException) { rejected = true; }
            Check(rejected, "Unsupported roster supplied a combat target.");
        }
        RoomState wrong = SelfCheckRoom(4, 2);
        wrong.Teams[2] = 1;
        wrong.States[2] = 3; wrong.ReadyRequested = true;
        Check(RoomAction(wrong) == RoomInput.Unready, "Wrong-team Ready bot did not unready first.");
        wrong.ReadyRequested = false;
        Check(RoomAction(wrong) == RoomInput.None, "Pending Unready could switch team prematurely.");
        wrong.States[2] = 1;
        Check(RoomAction(wrong) == RoomInput.SwitchTeam, "Unready bot did not request its assigned team.");
        wrong.Teams[2] = 0;
        Check(RoomAction(wrong) == RoomInput.Ready, "Corrected teams did not converge to Ready.");
        wrong.Teams[2] = 1; wrong.Teams[3] = 0; wrong.SelfSlot = 1;
        Check(RoomAction(wrong) == RoomInput.None, "Balanced but misassigned teams were accepted for Ready.");
        foreach (int[] slots in new[] { new[] { 0, 1, 2, 3 }, new[] { 7, 4, 0, 2 } })
            foreach (int playerTeam in new[] { 0, 1 })
                for (int teammate = 1; teammate < 4; teammate++)
                    for (int bot = 1; bot < 4; bot++)
                    {
                        RoomState room = SelfCheckRoom(4, bot, slots: slots, playerTeam: playerTeam);
                        for (int index = 0; index < 4; index++)
                            room.Teams[slots[index]] = (byte)(index == 0 || index == teammate ? playerTeam : 1 - playerTeam);
                        Check((RosterIssue(room, true, true) == null) == (teammate == 2),
                            "A different battle pairing weakened the preferred room assignment.");
                        State battle = SelfCheckState(room);
                        Check(RosterIssue(room, true, true) == null && RoomAction(room) == RoomInput.None &&
                            FriendlyBodies(battle).Length == 1,
                            "An actual balanced battle pairing paused combat or lost its living teammate.");
                        foreach (int active in slots)
                        {
                            int target = ResolveTargetSlot(room, battle.Units, active);
                            Check(target >= 0 && room.Teams[target] != room.Teams[room.SelfSlot],
                                "A reassigned battle pairing targeted a native teammate.");
                        }
                        room.Teams[room.SelfSlot] = (byte)(1 - room.Teams[room.SelfSlot]);
                        bool unbalancedRejected = false;
                        try { ResolveTargetSlot(room, battle.Units, room.SelfSlot); }
                        catch (InvalidDataException) { unbalancedRejected = true; }
                        Check(unbalancedRejected, "An unbalanced battle roster supplied a combat target.");
                    }
        RoomState master = SelfCheckRoom(4, 1, 1);
        master.States[0] = master.States[2] = 3;
        Check(RoomAction(master) == RoomInput.None, "Bot master started without BotThree Ready.");
        master.States[3] = 3;
        Check(RoomAction(master) == RoomInput.Start, "Complete native Ready roster did not permit legacy master Start.");
        master.InputBlocked = true;
        Check(RoomAction(master) == RoomInput.None, "A native popup did not block room input.");
        master.InputBlocked = false;
        master.States[3] = 2;
        Check(RoomAction(master) == RoomInput.None, "A joining slot was treated as Ready.");
        State combat = SelfCheckState(SelfCheckRoom(4));
        Check(RoomAction(combat.Room) == RoomInput.None, "A battle roster requested another Start/Ready.");
        Check(FriendlyBodies(combat).Length == 1, "2v2 friendly geometry omitted the living teammate.");
        combat.Units[3].Alive = false;
        Check(FriendlyBodies(combat).Length == 0, "A dead teammate was used as a living trajectory obstacle.");
        combat.Units[3] = null;
        bool missing = false;
        try { FriendlyBodies(combat); } catch (InvalidDataException) { missing = true; }
        Check(missing, "Missing teammate telemetry was treated as a dead unit.");
        var request = new RoomRequest { Before = SelfCheckRoom(4), Action = RoomInput.Ready };
        RoomState after = SelfCheckRoom(4);
        after.States[3] = 3;
        Check(request.Pending(after), "Another bot's Ready rearmed a pending toggle.");
        after.States[1] = 3; after.ReadyRequested = true;
        Check(!request.Pending(after), "Native Ready confirmation did not settle the request.");
        request = new RoomRequest { Before = SelfCheckRoom(4, 2), Action = RoomInput.SwitchTeam };
        after = SelfCheckRoom(4, 2);
        after.Teams[1] = 0;
        Check(request.Pending(after), "Another bot's team switch rearmed a pending toggle.");
        after.Teams[2] = 1;
        Check(!request.Pending(after), "Native self team confirmation did not settle the request.");
        RoomState peer = SelfCheckRoom(4, 3);
        Check(SameRoom(SelfCheckRoom(4), peer), "Same-room peer handoff depends on matching self slots.");
        peer.RoomId++;
        Check(!SameRoom(SelfCheckRoom(4), peer), "A different native room was allowed to hand off focus.");
        Check(Living(1, 100) && !Living(1, 0) && !Living(1, -1) && !Living(0, 100),
            "Native alive/health semantics changed.");
        bool badLife = false;
        try { Living(2, 100); } catch (InvalidDataException) { badLife = true; }
        Check(badLife, "Unknown native life values were accepted.");
    }

    static void NativeUnitsSelfCheck()
    {
        var words = new Dictionary<uint, uint> {
            { 0x8713C, 0x20000 }, { 0x2001C, 0x21000 }, { 0x21004, 0x186A1 }, { 0x21010, 0x30000 },
            { 0x30004, 0x186A1 }, { 0x30008, 1 }, { 0x30010, 0x40000 },
            { 0x40004, 0x186A1 }, { 0x40008, 7 }, { 0x40010, 0x21000 }
        };
        uint[] units = UnitPointers(address => words[address], 0x10000);
        Check(units[1] == 0x30000 && units[7] == 0x40000 && units.Count(unit => unit != 0) == 2,
            "Native circular unit lookup changed.");
        words[0x40010] = 0x30000;
        bool cycle = false;
        try { UnitPointers(address => words[address], 0x10000); } catch (SnapshotBusyException) { cycle = true; }
        Check(cycle, "A corrupt native unit cycle was not bounded.");
        words[0x40010] = 0x21000; words[0x40008] = 1;
        bool duplicate = false;
        try { UnitPointers(address => words[address], 0x10000); } catch (InvalidDataException) { duplicate = true; }
        Check(duplicate, "Duplicate native unit slots were accepted.");
    }

    static void InputSelfCheck()
    {
        Check(GuestInputMutex == @"Local\GunBoundAILab.GuestInput" &&
            SingletonName(@"C:\GunBoundAI\instances\BotOne") == SingletonName(@"c:\gunboundai\instances\BOTONE\") &&
            SingletonName(@"C:\GunBoundAI\instances\BotOne") != SingletonName(@"C:\GunBoundAI\instances\BotTwo"),
            "Guest input or stable per-instance singleton namespace changed.");
        Check(InputsIdle(key => false) && !InputsIdle(key => key == 32) &&
            !InputsIdle(key => key == 39) && !InputsIdle(key => key == 13) && !InputsIdle(key => key == 1),
            "Existing guest key ownership was ignored.");
        bool attempted, refused = false;
        try { TakeTurn(0, null, null, null, out attempted); }
        catch (InvalidOperationException) { refused = true; }
        Check(refused && !OwnsInput, "A controller could begin input without the shared mutex.");
        string name = @"Local\GunBoundAILab.ControllerSelfCheck." + Guid.NewGuid().ToString("N");
        using (var first = new Mutex(false, name))
        using (var second = new Mutex(false, name))
        {
            bool abandoned;
            int cleaned = 0;
            Check(TryAcquireInput(first, out abandoned) && !abandoned && OwnsInput, "Input owner was not recorded.");
            Exception failure = null;
            var waiter = new Thread(delegate() {
                try
                {
                    bool recovered;
                    Check(!TryAcquireInput(second, out recovered) && !OwnsInput, "A waiting controller acquired another bot's input.");
                    EndInput(second, delegate { Interlocked.Increment(ref cleaned); });
                    OnConsoleExit(0);
                }
                catch (Exception error) { failure = error; }
            });
            waiter.Start();
            Check(waiter.Join(2000), "Input waiter self-check exceeded its bound.");
            if (failure != null) throw failure;
            Check(cleaned == 0 && OwnsInput && stopping, "A waiter/console handler released another owner's keys.");
            stopping = false; stopReason = null;
            EndInput(first, delegate { cleaned++; });
            Check(cleaned == 1 && !OwnsInput && TryAcquireInput(second, out abandoned),
                "Input ownership was not released exactly once.");
            bool cleanupFailed = false;
            try { EndInput(second, delegate { throw new InvalidOperationException("test cleanup"); }); }
            catch (InvalidOperationException) { cleanupFailed = true; }
            Check(cleanupFailed && !OwnsInput, "A cleanup exception retained input ownership.");
            var exitedOwner = new Thread(delegate() { first.WaitOne(); });
            exitedOwner.Start();
            Check(exitedOwner.Join(2000), "Abandoned-owner self-check exceeded its bound.");
            Check(TryAcquireInput(second, out abandoned) && abandoned && OwnsInput, "Abandoned input ownership was not reported.");
            EndInput(second, delegate { });
        }
    }

    static void InputFaultSelfCheck()
    {
        const string shared = @"C:\GunBoundAI\session\guest-input-fault.json";
        foreach (string root in new[] { @"C:\GunBoundAI", @"C:\GunBoundAI\instances\BotOne",
            @"C:\GunBoundAI\instances\BotTwo", @"c:\gunboundai\instances\BOTTHREE\" })
            Check(GuestInputFaultPath(root) == shared, "An approved guest root lost the sticky input signal.");
        foreach (string root in new[] { @"C:\HostLab", @"C:\GunBoundAI-other",
            @"C:\GunBoundAI\instances", @"C:\GunBoundAI\instances\BotFour",
            @"C:\GunBoundAI\instances\BotOne\child" })
            Check(GuestInputFaultPath(root) == null, "The guest input fault signal escaped its exact root scope.");
        Check(!FaultPresent(null, path => { throw new InvalidOperationException("Host must not probe the signal."); }) &&
            !FaultPresent("unused", path => { throw new FileNotFoundException(); }) &&
            FaultPresent("unused", path => { throw new UnauthorizedAccessException(); }) &&
            FaultPresent("unused", path => { throw new IOException(); }),
            "Unreadable signal state was accepted as absent, or the host accessed it.");
        byte[] bounded = InputFaultBytes("guest-input-abandoned", @"C:\GunBoundAI", 123,
            @"C:\GunBoundAI\bot-controller.exe", 123456789, new string('x', 1000));
        var boundedRecord = Json.Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetString(bounded));
        Check(bounded.Length <= 4096 && ((string)boundedRecord["diagnostic"]).Length == 512,
            "Sticky fault diagnostic exceeded the 512-character contract.");
        bounded = InputFaultBytes("input-cleanup-failed", @"C:\GunBoundAI", 123, new string('p', 2000),
            123456789, new string('\0', 512));
        boundedRecord = Json.Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetString(bounded));
        Check(bounded.Length <= 4096 && ((string)boundedRecord["diagnostic"]).Length < 512 &&
            ((string)((Dictionary<string, object>)boundedRecord["process"])["path"]).Length == 2000,
            "JSON escaping exceeded the signal byte ceiling or truncated process identity.");
        string directory = Path.Combine(LabClient.Root, "input-fault-check-" + Guid.NewGuid().ToString("N"));
        string previousFile = inputFaultFile, previousReason = stopReason;
        bool previousObserved = inputFaultObserved, previousStopping = stopping;
        using (var mutex = new Mutex(false, @"Local\GunBoundAILab.InputFaultSelfCheck." + Guid.NewGuid().ToString("N")))
        try
        {
            inputFaultFile = Path.Combine(directory, "abandoned.json");
            inputFaultObserved = false; stopping = false; stopReason = null;
            bool refused = false, abandoned;
            try { PublishInputFault("guest-input-abandoned", "not owned"); }
            catch (InvalidOperationException) { refused = true; }
            Check(refused && !FaultPresent(inputFaultFile), "An unowned thread published an input fault.");
            var owner = new Thread(delegate() { mutex.WaitOne(); });
            owner.Start();
            Check(owner.Join(2000), "Fault publisher abandonment check exceeded its bound.");
            Check(TryAcquireInput(mutex, out abandoned) && abandoned && OwnsInput && FaultPresent(inputFaultFile),
                "Abandoned ownership was released without publishing the sticky guest signal.");
            byte[] original = File.ReadAllBytes(inputFaultFile);
            var record = Json.Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetString(original));
            var identity = (Dictionary<string, object>)record["process"];
            Check((int)record["schemaVersion"] == 1 && (string)record["event"] == "guest-input-abandoned" &&
                (string)record["sourceRoot"] == LabClient.Root && (int)identity["pid"] > 0 &&
                Convert.ToInt64(identity["startedUtcTicks"]) > 0 && (string)identity["path"] != "" &&
                (string)record["issuedUtc"] != "", "Sticky input fault schema/process identity changed.");
            PublishInputFault("input-cleanup-failed", "must not overwrite first writer");
            Check(original.SequenceEqual(File.ReadAllBytes(inputFaultFile)), "An earlier input fault was overwritten.");
            int cleaned = 0;
            EndInput(mutex, delegate { cleaned++; });
            Check(cleaned == 1 && !OwnsInput, "A sticky fault blocked cleanup of this process's own input.");
            inputFaultObserved = false; stopping = false; stopReason = null;
            refused = false;
            try { TryAcquireInput(mutex, out abandoned); }
            catch (InvalidOperationException) { refused = true; }
            Check(refused && !OwnsInput && stopping, "A new input transaction ignored the sticky fault.");
            inputFaultFile = Path.Combine(directory, "absent-after-observation.json");
            refused = false;
            try { TryAcquireInput(mutex, out abandoned); }
            catch (InvalidOperationException) { refused = true; }
            Check(refused && !FaultPresent(inputFaultFile), "A latched fault cleared merely because its marker disappeared.");

            inputFaultFile = Path.Combine(directory, "malformed.json");
            inputFaultObserved = false; stopping = false; stopReason = null;
            Check(TryAcquireInput(mutex, out abandoned), "Malformed-signal fixture could not own its test arbiter.");
            using (var file = new FileStream(inputFaultFile, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                file.WriteByte((byte)'{');
                Check(FaultPresent(inputFaultFile), "An incomplete/exclusively held signal was treated as absent.");
            }
            PublishInputFault("guest-input-abandoned", "must not replace malformed signal");
            Check(File.ReadAllText(inputFaultFile) == "{", "Malformed input fault was repaired or overwritten.");
            EndInput(mutex, delegate { cleaned++; });
            var diagnostic = Json.Deserialize<Dictionary<string, object>>(Json.Serialize(
                RoomDiagnostic(SelfCheckRoom(2, 0), 9)));
            Check((bool)diagnostic["Available"] && (string)diagnostic["SelfName"] == "Player" &&
                (string)diagnostic["action"] == "None", "The sticky signal contaminated read-only room diagnostics.");
            using (var process = Process.GetCurrentProcess())
            {
                diagnostic = Json.Deserialize<Dictionary<string, object>>(Json.Serialize(ObserveRoom(process.Id)));
                Check(((string)diagnostic["Diagnostic"]).Contains("GunBound.gme"),
                    "Read-only probing evaluated the sticky input fault instead of native client validation.");
            }

            inputFaultFile = Path.Combine(directory, "cleanup.json");
            inputFaultObserved = false; stopping = false; stopReason = null;
            Check(TryAcquireInput(mutex, out abandoned), "Cleanup fault fixture could not own its arbiter.");
            bool failed = false;
            try { EndInput(mutex, delegate { throw new InvalidOperationException("test owned cleanup failure"); }); }
            catch (InvalidOperationException) { failed = true; }
            record = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(inputFaultFile));
            Check(failed && !OwnsInput && (string)record["event"] == "input-cleanup-failed",
                "Owned cleanup failure did not publish the sticky signal before releasing the arbiter.");
        }
        finally
        {
            EndInput(mutex, delegate { });
            inputFaultFile = previousFile; inputFaultObserved = previousObserved;
            stopping = previousStopping; stopReason = previousReason;
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
        }
    }

    static void FirstImpactSelfCheck()
    {
        try
        {
            ResetTactics(null);
            State state = SelfCheckState(SelfCheckRoom(4));
            state.X = 100; state.Units[state.Slot].X = 100;
            state.Units[0].X = 350; state.Units[0].Y = 340;
            state.Units[2].X = 700; state.Units[2].Y = 500;
            state.Units[3].X = 385; state.Units[3].Y = 392;
            state = ForTarget(state, 2);
            var aim = new AimState { GunAngle = 45, WorldAngle = 45, Minimum = 5, Maximum = 80,
                Width = 24, Height = 48, MoveRemaining = 45, MoveMaximum = 100 };
            var cells = new byte[800 * 600];
            for (int y = 500; y < 600; y++)
                for (int x = 0; x < 800; x++) cells[y * 800 + x] = 1;
            for (int y = 340; y <= 499; y++)
                for (int x = 338; x <= 362; x++) cells[y * 800 + x] = 1;
            for (int y = 392; y <= 499; y++)
                for (int x = 373; x <= 397; x++) cells[y * 800 + x] = 1;
            var terrain = new ArmorBallistics.Terrain(800, 600, cells);
            var selected = new ArmorBallistics.Body(700, 500, 24, 48);
            ArmorBallistics.Body[] others = OtherEnemyBodies(state);
            Check(others.Length == 1 && others[0].NativeSlot == 0,
                "First-impact bodies included the shooter/friend/selected target, or omitted a living opposing slot.");
            var nativeSelected = new ArmorBallistics.Body(700, 500, 24, 48, 2);
            int omittedDirect = 0, allBodyRejected = 0;
            foreach (int angle in new[] { 44, 45, 46 })
                foreach (int power in new[] { 196, 200, 204 })
                {
                    ArmorBallistics.Shot omitted = ArmorBallistics.Trace(terrain, 120, 439, 700, 476, angle, power, 0, 0,
                        gravity: 73.5, windScale: 0.74, friendlies: FriendlyBodies(state), targetBody: selected, model: null);
                    if (omitted.End == ArmorBallistics.EndKind.Target && omitted.Clear &&
                        SafeTrajectory(state, omitted, 100, 500)) omittedDirect++;
                    ArmorBallistics.Shot allBodies = ArmorBallistics.Trace(terrain, 120, 439, 700, 476, angle, power, 0, 0,
                        gravity: 73.5, windScale: 0.74, friendlies: FriendlyBodies(state), targetBody: nativeSelected,
                        model: null, otherEnemies: others);
                    if (allBodies.End == ArmorBallistics.EndKind.OtherEnemy && allBodies.HitSlot == 0 &&
                        !allBodies.Clear && allBodies.FriendlyBlocked && !allBodies.TerrainImpact &&
                        !SafeTrajectory(state, allBodies, 100, 500)) allBodyRejected++;
                }
            Check(omittedDirect == 9 && allBodyRejected == 9,
                "The exact review fixture did not reproduce/reject all nine direct Trace probes with the S1 safety predicate.");
            ArmorBallistics.Shot interveningTarget = ArmorBallistics.Trace(terrain, 120, 439, 350, 316, 45, 200, 0, 0,
                gravity: 73.5, windScale: 0.74, friendlies: FriendlyBodies(state),
                targetBody: new ArmorBallistics.Body(350, 340, 24, 48), model: null);
            ArmorBallistics.Shot firstBody = ArmorBallistics.Trace(terrain, 120, 439, 700, 476, 45, 200, 0, 0,
                gravity: 73.5, windScale: 0.74, friendlies: FriendlyBodies(state), targetBody: nativeSelected,
                model: null, otherEnemies: others);
            Check(interveningTarget.FriendlyBlocked && !interveningTarget.Clear && !interveningTarget.TerrainImpact &&
                Math.Abs(interveningTarget.LandingX - 338.319218691347) < 1e-9 &&
                Math.Abs(interveningTarget.LandingY - 305.435468808653) < 1e-9 &&
                firstBody.End == ArmorBallistics.EndKind.OtherEnemy && firstBody.FriendlyBlocked &&
                firstBody.LandingX == interveningTarget.LandingX && firstBody.LandingY == interveningTarget.LandingY,
                "Direct Trace did not stop at the reviewer's exact earlier body/blast-risk intersection.");
            bool missingEnemies = false;
            try { ArmorBallistics.Trace(terrain, 120, 439, 700, 476, 45, 200, 0, 0,
                targetBody: new ArmorBallistics.Body(700, 500, 24, 48, 2)); }
            catch (ArgumentException) { missingEnemies = true; }
            Check(missingEnemies, "A native-target trace silently accepted a missing enemy observation.");
            Robustness blocked = AssessShot(state, aim, terrain, 100, 500, 0, 1, 45, 200, 1);
            Check(blocked.Samples == 9 && !blocked.Safe && blocked.SafeSamples < blocked.Samples && blocked.DirectSamples == 0 &&
                !blocked.NominalDirect && blocked.Nominal.End == ArmorBallistics.EndKind.OtherEnemy &&
                blocked.Nominal.HitSlot == 0 && blocked.Nominal.FriendlyBlocked &&
                Math.Abs(blocked.Nominal.LandingX - 338.32) < 0.02 && Math.Abs(blocked.Nominal.LandingY - 305.44) < 0.02 &&
                !UsableShot(state, blocked.Nominal, 100, 500, 0, 1, true),
                "The intervening enemy did not stop the shot at the actual teammate-risk impact: " + Json.Serialize(blocked));
            Robustness noisy = AssessShot(state, aim, terrain, 100, 500, 0, 1, 44, 197, 1);
            Check(!noisy.Safe && noisy.DirectSamples == 0 && noisy.Nominal.FriendlyBlocked &&
                noisy.Nominal.HitSlot == 0, "The final noisy assessment bypassed an enemy intercept near a teammate.");
            int evaluated = 0;
            var stats = new SearchStats { TargetSlot = 2 };
            Check(SearchAt(state, aim, terrain, 100, 500, 0, 700, 476, 1, Stopwatch.StartNew(), null,
                ref evaluated, true, stats: stats) == null && stats.OtherEnemyStops > 0 && stats.FriendlyStops > 0,
                "Nominal power/angle planning omitted the first enemy impact or its rejection diagnostics.");
            GoodShots.Add(new ShotMemory { Context = state, TerrainKey = TerrainKey(terrain), WeaponKey = WeaponKey(1),
                Weapon = 1, GunAngle = 45, Power = 200 });
            Check(SearchAt(state, aim, terrain, 100, 500, 0, 700, 476, 1, Stopwatch.StartNew(), null,
                ref evaluated, true) == null, "An exact-context remembered shot bypassed the new first-impact check.");
            Check(SearchAt(state, aim, terrain, 88, 500, 0, 700, 476, 1, Stopwatch.StartNew(), null,
                ref evaluated, true) == null, "A prospective reposition/goal trajectory omitted an intervening enemy.");
            GoodShots.Clear();

            state.Units[3].X = 20; state.Units[3].Y = 500;
            Robustness safeIntercept = AssessShot(state, aim, terrain, 100, 500, 0, 1, 45, 200, 1);
            Check(safeIntercept.Safe && safeIntercept.DirectSamples == 0 && !safeIntercept.NominalDirect &&
                !safeIntercept.Nominal.Clear && safeIntercept.Nominal.HitSlot == 0 &&
                UsableShot(state, safeIntercept.Nominal, 100, 500, 0, 1, true) &&
                !UsableShot(state, safeIntercept.Nominal, 100, 500, 0) && state.TargetSlot == 2,
                "A safe non-selected interception was counted as a selected hit, treated as excavation, or silently retargeted.");
            var frontWallCells = (byte[])cells.Clone();
            for (int y = 0; y < 600; y++) frontWallCells[y * 800 + 250] = 1;
            ArmorBallistics.Shot frontWall = ArmorBallistics.Trace(new ArmorBallistics.Terrain(800, 600, frontWallCells),
                120, 439, 700, 476, 45, 200, 0, 0, targetBody: new ArmorBallistics.Body(700, 500, 24, 48, 2),
                otherEnemies: OtherEnemyBodies(state), friendlies: FriendlyBodies(state));
            Check(frontWall.TerrainImpact && frontWall.HitSlot == -1 && frontWall.LandingX < 250 && !frontWall.Clear,
                "An enemy body behind the first terrain collision received hit credit.");
            State firstSelected = ForTarget(state, 0);
            Robustness selectedFirst = AssessShot(firstSelected, aim, terrain, 100, 500, 0, 1, 45, 200, 1);
            Check(selectedFirst.Safe && selectedFirst.DirectSamples == 9 && selectedFirst.NominalDirect &&
                selectedFirst.Nominal.HitSlot == 0, "An unobstructed selected first body was rejected in favor of an enemy behind it.");
            state.Units[0].Alive = false; state.Units[0].Health = 0;
            Robustness unobstructed = AssessShot(state, aim, terrain, 100, 500, 0, 1, 45, 200, 1);
            Check(OtherEnemyBodies(state).Length == 0 && unobstructed.Safe && unobstructed.DirectSamples == 9 &&
                unobstructed.Nominal.HitSlot == 2, "A dead opposing body or the shooter still blocked the selected target.");

            state.Slope = -90; aim.WorldAngle = -45;
            state.Units[0].Alive = true; state.Units[0].Health = 1000;
            state.Units[0].X = 140; state.Units[0].Y = 520;
            state.Units[2].X = 300; state.Units[2].Y = 760;
            state = ForTarget(state, 2);
            var dropCells = new byte[800 * 900];
            for (int y = 500; y < 900; y++)
                for (int x = 0; x <= 114; x++) dropCells[y * 800 + x] = 1;
            for (int x = 128; x <= 152; x++) dropCells[520 * 800 + x] = 1;
            for (int x = 260; x <= 340; x++) dropCells[760 * 800 + x] = 1;
            var drop = new ArmorBallistics.Terrain(800, 900, dropCells);
            Robustness selfRisk = AssessShot(state, aim, drop, 100, 500, -90, 1, 45, 200, 1);
            Check(!selfRisk.Safe && selfRisk.DirectSamples == 0 && !selfRisk.Nominal.FriendlyBlocked &&
                selfRisk.Nominal.End == ArmorBallistics.EndKind.OtherEnemy && selfRisk.Nominal.HitSlot == 0 &&
                (selfRisk.Nominal.LandingX - 100) * (selfRisk.Nominal.LandingX - 100) +
                (selfRisk.Nominal.LandingY - 475) * (selfRisk.Nominal.LandingY - 475) < 40 * 40 &&
                !UsableShot(state, selfRisk.Nominal, 100, 500, -90, 1, true),
                "An enemy intercept inside the self-blast margin was authorized: " + Json.Serialize(selfRisk));
            state.Units[0].Alive = false; state.Units[0].Health = 0;
            Robustness launch = AssessShot(state, aim, drop, 100, 500, -90, 1, 45, 200, 1);
            Check(launch.Safe && launch.DirectSamples == 9 && launch.Nominal.HitSlot == 2,
                "Shooter launch geometry was treated as a terminal self-body collision: " + Json.Serialize(launch));
        }
        finally { ResetTactics(null); }
        Console.WriteLine("PASS: exact reviewer fixture/direct Trace probes, all-enemy first impact, teammate/self blast rejection, safe non-selected/selected hits, dead/shooter exclusion, noisy/cached/repositioned trajectories.");
    }

    static void SmartCombatSelfCheck()
    {
        Difficulty previousDifficulty = activeDifficulty;
        Shot2Calibration previousShot2 = shot2;
        try
        {
            var profiles = Profiles("BotOne");
            activeDifficulty = profiles.Tiers["hard"]; shot2 = profiles.ArmorShot2;
            ResetTactics(null); movementSpent = 0;
            FirstImpactSelfCheck();
            var cells = new byte[800 * 600];
            for (int y = 500; y < 600; y++)
                for (int x = 0; x < 800; x++) cells[y * 800 + x] = 1;
            var flat = new ArmorBallistics.Terrain(800, 600, cells);
            string key = TerrainKey(flat);
            State state = SelfCheckState(SelfCheckRoom(2, slots: new[] { 1, 0 }));
            state.Units[state.TargetSlot].X = 700; state = ForTarget(state, state.TargetSlot);
            EnsureMatch(state);
            var aim = new AimState { GunAngle = 45, WorldAngle = 45, Minimum = 5, Maximum = 80,
                Minimum1 = 25, Maximum1 = 50, Width = 24, Height = 48, MoveRemaining = 45, MoveMaximum = 100 };
            int evaluated = 0;
            ShotPlan clear = SearchAt(state, aim, flat, state.X, state.Y, state.Slope, state.TargetX, state.TargetY,
                2, Stopwatch.StartNew(), null, ref evaluated);
            Check(clear != null && clear.Shot.Clear && clear.Confidence.Safe && clear.Confidence.Samples == 9 &&
                clear.Confidence.Percent > 0 && clear.Confidence.Percent <= 100 &&
                clear.Confidence.Meaning.Contains("NOT calibrated") &&
                Json.Serialize(clear.Confidence).Contains("\"DirectSamples\""),
                "Confidence is not a bounded, labelled trajectory-perturbation estimate.");
            ObserveCharge(200, 218);
            Robustness stressed = AssessShot(state, aim, flat, 100, 500, 0, 1, clear.GunAngle, clear.Shot.Power, 1);
            Check(chargeUncertainty == 20 && stressed.Percent < clear.Confidence.Percent,
                "Observed charge error did not conservatively widen/lower the model robustness estimate.");
            chargeUncertainty = 4;
            var wallBytes = (byte[])cells.Clone();
            for (int y = 0; y < 600; y++) wallBytes[y * 800 + 690] = 1;
            var wall = new ArmorBallistics.Terrain(800, 600, wallBytes);
            Robustness occluded = AssessShot(state, aim, wall, 100, 500, 0, 1, clear.GunAngle, clear.Shot.Power, 1);
            Check(occluded.DirectSamples == 0 && !occluded.NominalDirect,
                "A wall adjacent to the target was scored as a through-terrain body hit.");

            State teams = SelfCheckState(SelfCheckRoom(4));
            teams.X = 400; teams.Units[teams.Slot].X = 400;
            teams.Units[0].X = 220; teams.Units[2].X = 740; teams.Units[3].X = 100;
            teams = ForTarget(teams, 0);
            var teamBytes = (byte[])cells.Clone();
            for (int y = 0; y < 600; y++) teamBytes[y * 800 + 300] = 1;
            var teamTerrain = new ArmorBallistics.Terrain(800, 600, teamBytes);
            aim.Maximum = 50;
            var nearestStats = new SearchStats { TargetSlot = 0 };
            ShotPlan nearest = SearchAt(teams, aim, teamTerrain, 400, 500, 0, teams.TargetX, teams.TargetY,
                2, Stopwatch.StartNew(), null, ref evaluated, stats: nearestStats);
            Check((nearest == null || !nearest.Shot.Clear) && nearestStats.TerrainStops > 0,
                "The nearest-enemy regression did not observe a real obstruction/rejection breakdown.");
            ShotPlan farther = ChooseTactics(teams, aim, teamTerrain, null, new Stopwatch(), false);
            Check(farther != null && !farther.MoveOnly && farther.Shot.Clear && farther.TargetSlot == 2,
                "The blocked nearest enemy hid a farther attackable living enemy.");
            Check(WorldAngle(teams, aim, 60, 10, 0) == 130, "Prospective opposite-facing slope/angle projection is wrong.");
            double leftX, leftY, rightX, rightY;
            Muzzle(400, 500, 0, 0, out leftX, out leftY); Muzzle(400, 500, 0, 1, out rightX, out rightY);
            Check(leftX < 400 && rightX > 400 && Math.Abs(leftY - rightY) < 0.001,
                "An opposite-side enemy used the wrong prospective muzzle.");
            State chosen = LockTarget(teams, 2);
            Check(ObservedTarget(teams) == 2 && CanChargeGeometry(chosen, chosen, chosen, aim, aim, 1),
                "The chosen target did not propagate through observed-state/charge authorization.");
            State movingLock = chosen.Copy();
            movingLock.Units = chosen.Units.Select(u => u == null ? null : u.Copy()).ToArray();
            movingLock.X += 12; movingLock.Units[movingLock.Slot].X += 12; movingLock.Facing = 0;
            CheckTurn(movingLock, chosen);
            Check(ObservedTarget(movingLock) == 2 && !CanChargeGeometry(chosen, movingLock, chosen, aim, aim, 1),
                "Movement/facing lost the chosen target lock or skipped exact-geometry reacquisition.");
            State different = ForTarget(teams, 0);
            Check(!CanChargeGeometry(chosen, different, chosen, aim, aim, 1), "Charging silently switched living enemies.");
            different = chosen.Copy(); different.TurnNumber++;
            Check(ObservedTarget(different) == 0 && !CanChargeGeometry(chosen, different, chosen, aim, aim, 1),
                "The target lock crossed a native turn.");
            different = chosen.Copy(); different.Battle++;
            Check(ObservedTarget(different) == 0, "The target lock crossed a battle.");
            different = chosen.Copy(); different.Units = chosen.Units.Select(u => u == null ? null : u.Copy()).ToArray();
            different.Units[2].Alive = false;
            Check(ObservedTarget(different) == -1 && !CanChargeGeometry(chosen, different, chosen, aim, aim, 1),
                "A dead locked enemy silently fell back to the nearest target.");
            bool allyRejected = false;
            try { LockTarget(teams, 3); } catch (LabClient.ChargeUnavailableException) { allyRejected = true; }
            Check(allyRejected, "A friendly target hint was accepted.");
            ResetTactics(state);

            aim.Minimum = 5; aim.Maximum = 45;
            bool improved = false;
            ShotPlan futureMove = null;
            ArmorBallistics.Terrain goalTerrain = null;
            // Search a small deterministic family of wall edges; the old "any clear shot => no moves" fails every member.
            for (int top = 270; top <= 350; top += 2)
            {
                var edgeBytes = (byte[])cells.Clone();
                for (int y = top; y < 600; y++) edgeBytes[y * 800 + 350] = 1;
                var edge = new ArmorBallistics.Terrain(800, 600, edgeBytes);
                ShotPlan standing = ChoosePlan(state, aim, edge, state.TargetX, state.TargetY, null, false, true);
                ShotPlan moving = ChoosePlan(state, aim, edge, state.TargetX, state.TargetY, null, true, true);
                if (standing != null && standing.Shot.Clear && moving != null && moving.Shot.Clear && moving.X != state.X &&
                    moving.Confidence.Percent > standing.Confidence.Percent) improved = true;
                if (futureMove == null && (moving == null || !moving.Shot.Clear))
                {
                    var watch = new Stopwatch();
                    ShotPlan possible = ChooseTactics(state, aim, edge, null, watch, true);
                    if (possible != null && possible.MoveOnly)
                    {
                        Check(watch.ElapsedMilliseconds < 2000, "Whole multi-position/lookahead evaluation exceeded its bounded budget.");
                        futureMove = possible; goalTerrain = edge;
                    }
                }
                if (improved && futureMove != null) break;
            }
            Check(improved, "A nominally clear but fragile standing shot still suppresses a more robust legal move-and-fire plan.");
            Check(futureMove != null && Math.Abs(futureMove.X - state.X) <= 48 &&
                Math.Abs(futureMove.GoalX - state.X) <= 96 && futureMove.X < state.X,
                "No supported movement-only/back-away firing goal was discovered in the two-hop fixture.");
            key = TerrainKey(goalTerrain);
            State moved = state.Copy(); moved.Units = state.Units.Select(u => u == null ? null : u.Copy()).ToArray();
            moved.X = futureMove.X; moved.Y = futureMove.Y; moved.Slope = (int)Math.Round(futureMove.Slope);
            moved.Units[moved.Slot].X = moved.X; moved.Units[moved.Slot].Y = moved.Y;
            RecordMove(state, moved, futureMove.GoalX, futureMove.GoalY, key);
            RecentPositions.Enqueue(state.X);
            Check(moveGoal != null && moveGoal.NoProgress == 0 &&
                !Positions(moved, aim, goalTerrain, true, key, null).Any(p => p.X == state.X),
                "Observed goal progress was lost or the next turn immediately oscillated backward.");
            ShotPlan continued = ChooseTactics(moved, aim, goalTerrain, null, new Stopwatch(), true);
            Check(continued != null && (continued.MoveOnly || continued.Shot.Clear),
                "A working goal was not re-simulated from the actual next-turn position.");
            RecentPositions.Clear(); moveGoal = null;
            RecordMove(state, state, futureMove.GoalX, futureMove.GoalY, key);
            RecordMove(state, state, state.X + 48, state.Y, key);
            Check(moveGoal.NoProgress == 2 && Positions(state, aim, goalTerrain, true, key, null).Count == 1,
                "Repeated unobserved/no-progress movement was allowed indefinitely.");
            ValidateGoal(state, key + "-changed");
            Check(moveGoal == null, "A changed terrain mask retained a cached movement goal.");
            RecordMove(state, state, futureMove.GoalX, futureMove.GoalY, key);
            different = state.Copy(); different.Wind++;
            ValidateGoal(different, key);
            Check(moveGoal == null, "Changed wind retained an old firing-position goal.");

            ResetTactics(state); key = TerrainKey(flat); aim.Maximum = 80;
            var pending = new PendingImpact { Turn = state, Before = flat, Shot = clear.Shot, DirectAttempt = true,
                GunAngle = clear.GunAngle, ObservedPower = clear.Shot.Power, Weapon = 1 };
            var observedUnits = state.Units.Select(u => u == null ? null : u.Copy()).ToArray();
            Check(!ObserveGoodShot(pending, observedUnits, true) && GoodShots.Count == 0,
                "A predicted clear shot alone was learned as success.");
            observedUnits[state.TargetSlot].Health -= 100;
            State releaseBaseline = state.Copy();
            releaseBaseline.Units = observedUnits.Select(u => u == null ? null : u.Copy()).ToArray();
            Check(!ObserveGoodShot(new PendingImpact { Turn = releaseBaseline, Before = flat, Shot = clear.Shot,
                DirectAttempt = true, GunAngle = clear.GunAngle, ObservedPower = clear.Shot.Power }, observedUnits, true),
                "HP already lost in the pre-release baseline was learned as post-release progress.");
            Check(!ObserveGoodShot(pending, observedUnits, false) && GoodShots.Count == 0,
                "Unowned HP loss was learned as this bot's shot.");
            Check(ObserveGoodShot(pending, observedUnits, true) && GoodShots.Count == 1 &&
                MemoryFor(state, key, 1).Power == pending.ObservedPower &&
                MemoryFor(state, key, 1).GunAngle == pending.GunAngle,
                "Owned intended-target HP evidence did not retain the actual observed gun angle/power.");
            aim.GunAngle = pending.GunAngle; aim.WorldAngle = pending.GunAngle;
            ShotPlan learned = SearchAt(state, aim, flat, 100, 500, 0, state.TargetX, state.TargetY, 2,
                Stopwatch.StartNew(), null, ref evaluated, true);
            Check(learned != null && learned.Learned && learned.Confidence.Safe,
                "An observed good-shot match was not re-traced and locked before noise reduction.");
            ShotPlan retained = ChooseTactics(state, aim, flat, null, new Stopwatch(), false, true);
            Check(retained != null && retained.Learned, "A revalidated observed good shot was discarded for unproven acquisition noise.");
            foreach (int kind in Enumerable.Range(0, 6))
            {
                different = state.Copy(); different.Units = state.Units.Select(u => u == null ? null : u.Copy()).ToArray();
                if (kind == 0) different.Wind++;
                if (kind == 1) different.Battle++;
                if (kind == 2) different.X++;
                if (kind == 3) different.Facing = 0;
                if (kind == 4) different.Slope++;
                if (kind == 5) different.Units[different.TargetSlot].X++;
                Check(MemoryFor(different, key, 1) == null, "Changed wind/battle/source/facing/slope/target retained a good-shot lock.");
            }
            Check(MemoryFor(state, key + "-changed", 1) == null && MemoryFor(state, key, 2) == null,
                "Terrain or weapon changes reused a cached power lock.");
            different = state.Copy(); different.Wind++;
            Check(MemoryAngles(different, 1).Contains(pending.GunAngle), "Changed conditions lost the bounded angle-only reacquisition hint.");
            string exactBeforeNoise = Json.Serialize(state);
            TurnNoise firstNoise = NoiseFor(state, activeDifficulty, new Random(7));
            Check(Object.ReferenceEquals(firstNoise, NoiseFor(state, activeDifficulty, new Random(8))),
                "Exploration noise was redrawn during the same native turn/retry.");
            different = SelfCheckState(SelfCheckRoom(2, slots: new[] { 1, 0 }));
            different.Room.InputBlocked = true;
            ObserveCharge(200, 218); EnsureMatch(different);
            Check(chargeUncertainty == 20 && Object.ReferenceEquals(firstNoise, NoiseFor(different, activeDifficulty, new Random(9))),
                "A dialog/roster observation reset measured charge uncertainty or redrew same-turn exploration.");
            chargeUncertainty = 4;
            for (int index = 0; index < 50; index++)
            {
                different = state.Copy(); different.TurnNumber += index + 1;
                TurnNoise sampled = NoiseFor(different, activeDifficulty, AimRandom);
                Check(Math.Abs(sampled.Angle) <= 1 && Math.Abs(sampled.Power) <= 3 &&
                    sampled.EstimateX == 0 && sampled.EstimateY == 0, "Hard exploratory noise exceeded its input-only envelope.");
            }
            int noisyGun, noisyPower, lockedGun, lockedPower;
            var deliberateNoise = new TurnNoise { Angle = 1, Power = 3 };
            aim.GunAngle = 45; aim.WorldAngle = 45;
            RequestedNoise(aim, 200, deliberateNoise, false, out noisyGun, out noisyPower);
            RequestedNoise(aim, 200, deliberateNoise, learned.Learned, out lockedGun, out lockedPower);
            Check(noisyGun == 46 && noisyPower == 203 && Math.Abs(lockedGun - 45) < 1 &&
                Math.Abs(lockedPower - 200) < 3 && Json.Serialize(state) == exactBeforeNoise,
                "Exploration was erased, did not reduce after a valid learned shot, or perturbed authoritative telemetry.");
            State near = state.Copy(); near.Units = state.Units.Select(u => u == null ? null : u.Copy()).ToArray();
            near.Units[near.TargetSlot].X = 450; near = ForTarget(near, near.TargetSlot);
            ArmorBallistics.Shot nearMiss = ArmorBallistics.Trace(flat, 120, 439, near.TargetX, near.TargetY, 45, 155, 0, 0,
                targetBody: new ArmorBallistics.Body(450, 500, 24, 48));
            Check(!nearMiss.Clear && nearMiss.TerrainImpact && UsableShot(near, nearMiss, 100, 500, 0, 1, true),
                "A safe intentional near miss was filtered back into a perfect direct hit: " + Json.Serialize(nearMiss));
            for (int index = 0; index < 6; index++)
            {
                different = state.Copy(); different.Wind = index;
                ObserveGoodShot(new PendingImpact { Turn = different, Before = flat, Shot = clear.Shot, DirectAttempt = true,
                    GunAngle = pending.GunAngle, ObservedPower = pending.ObservedPower }, observedUnits, true);
            }
            Check(GoodShots.Count == 4, "Match-scoped observed-shot memory grew beyond four entries.");
            different = state.Copy(); different.Battle++;
            EnsureMatch(different);
            Check(GoodShots.Count == 0 && targetLock == null && moveGoal == null && turnNoise == null,
                "A new battle retained tactical locks, noise, goals or good-shot memories.");

            var eighty = new Robustness { Samples = 5, SafeSamples = 5, DirectSamples = 4, NominalDirect = true };
            Check(shot2.Status == "deferred" && !shot2.Available && shot2.DisabledReason.Contains("ODoubleBullet") &&
                !CanUseShot2(eighty, true), "Deferred S2 lacks an explicit exact-client reason or confidence alone activated it.");
            Check(MeetsShot2Policy(eighty, true) && !MeetsShot2Policy(eighty, false) &&
                !MeetsShot2Policy(new Robustness { Samples = 9, SafeSamples = 9, DirectSamples = 7, NominalDirect = true }, true) &&
                !MeetsShot2Policy(new Robustness { Samples = 9, SafeSamples = 8, DirectSamples = 8, NominalDirect = true }, true),
                "The eventual >=80% DIRECT/all-variation-safety policy changed while calibration was deferred.");
            foreach (string status in new[] { "pending", "deferred" })
            {
                shot2 = new Shot2Calibration { Status = status, MinimumModelConfidencePercent = 80 };
                shot2.Validate();
                Check(!shot2.Available && !CanUseShot2(eighty, true), "An unset/deferred gate enabled automatic S2.");
            }
            foreach (string model in new[] { "independent-euler-0.05-v1", "claimed-native-double-impact-model" })
            {
                shot2 = new Shot2Calibration { Status = "verified", MinimumModelConfidencePercent = 80,
                    Model = model, Evidence = "SELF-CHECK CONFIGURATION CLAIM, NOT CALIBRATION",
                    SelectionKey = 9, NativeSelectionVerified = true };
                bool rejected = false;
                try { shot2.Validate(); } catch (InvalidDataException error) { rejected = error.Message.Contains("ODoubleBullet"); }
                Check(rejected && !shot2.Available && !CanUseShot2(eighty, true) &&
                    !Shot2Envelope(state, 100, 500, 0, 1, 45, 200),
                    "A JSON verified/model/evidence claim activated unsupported native S2 continuation physics.");
            }
            shot2 = profiles.ArmorShot2;
            bool noFallback = false;
            try { ProjectileModels(2); } catch (InvalidDataException error) { noFallback = error.Message.Contains("ODoubleBullet"); }
            Check(noFallback, "Deferred S2 substituted S1 or independent-projectile physics.");
            int beforeS2 = evaluated;
            Check(SearchAt(state, aim, flat, 100, 500, 0, state.TargetX, state.TargetY, 2,
                Stopwatch.StartNew(), null, ref evaluated, weapon: 2) == null && evaluated == beforeS2,
                "Deferred S2 still performed an unverified trajectory search.");
            foreach (int mode in new[] { 0, 1, 2 })
            {
                var nativeAim = new AimState { GunAngle = 45, WorldAngle = 45, Minimum = 5, Maximum = 80, ShotMode = mode };
                Check(!CanChargeGeometry(state, state, state, nativeAim, nativeAim, 2) &&
                    CanChargeGeometry(state, state, state, nativeAim, nativeAim, 1) == (mode == 0),
                    "Deferred S2 or SS reached charging, or native S1 mode validation was lost.");
                nativeAim.Minimum = 60; nativeAim.Maximum = 65;
                Check(!CanChargeGeometry(state, state, state, nativeAim, nativeAim, 1),
                    "Changed native angle limits did not invalidate the old gun angle.");
            }
        }
        finally
        {
            activeDifficulty = previousDifficulty; shot2 = previousShot2; movementSpent = 0;
            ResetTactics(null); repeatedMisses = 0; excavationTarget = null; failedExcavations = 0;
        }
        Console.WriteLine("PASS: all-enemy quality selection, useful moves/two-hop goals, target/facing locks, model robustness, observed-shot memory, once-per-turn noise, and hard-deferred S2/configuration rejection (no runtime calibration).");
    }

    static void ControllerSelfCheck()
    {
        int? humanPid;
        int botPid;
        ParseArguments(new[] { "--standalone", "200" }, out humanPid, out botPid);
        Check(!humanPid.HasValue && botPid == 200, "Standalone acquired a local human PID.");
        Check(PeerInMode(null, 9) && PeerInMode(null, 11), "Standalone tried to read a human mode.");
        Check(ForegroundAllowed(200, humanPid, botPid) && !ForegroundAllowed(100, humanPid, botPid) &&
            !ForegroundAllowed(0, humanPid, botPid), "Standalone permits input outside its own foreground client.");
        ParseArguments(new[] { "100", "200" }, out humanPid, out botPid);
        Check(humanPid == 100 && botPid == 200 && ForegroundAllowed(100, humanPid, botPid) &&
            ForegroundAllowed(200, humanPid, botPid) && !ForegroundAllowed(300, humanPid, botPid),
            "Legacy PID or focus behavior changed.");
        foreach (string[] input in new[] {
            new string[0], new[] { "--standalone" }, new[] { "--standalone", "0" },
            new[] { "--standalone", "-1" }, new[] { "--standalone", "not-a-pid" },
            new[] { "--standalone", "2147483648" }, new[] { "--standalone", "200", "300" },
            new[] { "--other", "200" }, new[] { "0", "200" }, new[] { "200", "200" }
        })
        {
            bool rejected = false;
            try { ParseArguments(input, out humanPid, out botPid); }
            catch (ArgumentException) { rejected = true; }
            Check(rejected, "An invalid controller command line was accepted.");
        }
        RosterSelfCheck();
        NativeUnitsSelfCheck();
        InputSelfCheck();
        InputFaultSelfCheck();
        foreach (int active in new[] { -1, 2, 7, 8, 255, Int32.MaxValue })
        {
            RoomState room = SelfCheckRoom(2);
            bool rejected = false;
            try { ResolveTargetSlot(room, SelfCheckUnits(room), active); }
            catch (InvalidDataException) { rejected = true; }
            Check(rejected, "An unoccupied/out-of-bounds active slot was accepted.");
        }
        var turns = new TurnTracker();
        turns.Reset(true);
        Check(turns.Observe(0x10000, 10, 1) && turns.CanAct, "A new match could not act.");
        Check(!turns.Observe(0x10000, 10, 1), "One native turn was replayed.");
        Check(turns.Observe(0x10000, 11, 1) && turns.Observe(0x10000, 12, 1),
            "Consecutive turns owned by the same bot were missed.");
        bool staleTurn = false;
        try { turns.Observe(0x10000, 11, 1); } catch (SnapshotBusyException) { staleTurn = true; }
        Check(staleTurn, "An older turn event was accepted.");
        turns.Reset(false);
        Check(turns.Observe(0x10000, 65535, 1) && !turns.CanAct &&
            turns.Observe(0x10000, 0, 1) && turns.CanAct, "Mid-turn attachment or turn-counter wrap changed.");
        var sameActor = new State { Mode = 11, Battle = 0x10000, TurnNumber = 5, ActiveSlot = 1 };
        Check(SameTurn(sameActor, new State { Mode = 11, Battle = 0x10000, TurnNumber = 5, ActiveSlot = 1 }) &&
            !SameTurn(sameActor, new State { Mode = 11, Battle = 0x10000, TurnNumber = 6, ActiveSlot = 1 }),
            "Input ownership cannot distinguish consecutive bot turns.");
        Check(ImpactOwner(0x20000, 5, 0x20000, 5, false) &&
            ImpactOwner(0x20000, 5, 0x20000, 6, false) &&
            !ImpactOwner(0x20000, 5, 0x20000, 6, true) &&
            !ImpactOwner(0x20000, 5, 0x30000, 6, false), "Impact attribution crossed into another actionable turn.");
        var terrainBytes = new byte[800 * 600];
        for (int y = 500; y < 600; y++)
            for (int x = 0; x < 800; x++) terrainBytes[y * 800 + x] = 1;
        for (int y = 200; y < 600; y++) terrainBytes[y * 800 + 350] = 1;
        State planningState = SelfCheckState(SelfCheckRoom(2, slots: new[] { 1, 0 }));
        planningState.X = 100; planningState.Y = 500; planningState.TargetX = 700; planningState.TargetY = 455;
        planningState.Units[planningState.TargetSlot].X = 700;
        var planningAim = new AimState { GunAngle = 10, WorldAngle = 10, Minimum = 0, Maximum = 80,
            Minimum1 = 25, Maximum1 = 40, Minimum2 = 0, Maximum2 = 0 };
        int evaluated = 0;
        ShotPlan highArc = SearchAt(planningState, planningAim, new ArmorBallistics.Terrain(800, 600, terrainBytes),
            100, 500, 0, 700, 455, 2, Stopwatch.StartNew(), null, ref evaluated);
        Check(highArc != null && highArc.Shot.Clear && highArc.GunAngle > 40 && planningAim.Legal(highArc.GunAngle),
            "The planner failed to leave a terrain-blocked low angle for a legal high arc.");
        var blockedBytes = (byte[])terrainBytes.Clone();
        for (int y = 0; y < 600; y++) blockedBytes[y * 800 + 350] = 1;
        var blockedTerrain = new ArmorBallistics.Terrain(800, 600, blockedBytes);
        var digAim = new AimState { GunAngle = 45, WorldAngle = 45, Minimum = 0, Maximum = 45,
            Width = 24, Height = 48, MoveRemaining = 100, MoveMaximum = 100 };
        ShotPlan dig = SearchAt(planningState, digAim, blockedTerrain, 100, 500, 0, 700, 455, 2,
            Stopwatch.StartNew(), null, ref evaluated);
        Check(dig != null && !dig.Shot.Clear && dig.Shot.TerrainImpact && digAim.Legal(dig.GunAngle) &&
            UsableShot(planningState, dig.Shot, 100, 500, 0),
            "The blocked controller plan did not retain a useful safe terrain impact.");
        double muzzleX, muzzleY;
        Muzzle(100, 500, 0, 1, out muzzleX, out muzzleY);
        var emptyTerrain = new ArmorBallistics.Terrain(800, 600, new byte[800 * 600]);
        ArmorBallistics.Shot selfImpact = ArmorBallistics.Trace(blockedTerrain, muzzleX, muzzleY, 700, 455, -90, 40, 0, 0);
        Check(selfImpact.TerrainImpact, "The self-risk check did not actually hit supporting terrain.");
        var supportBytes = (byte[])terrainBytes.Clone();
        for (int y = 0; y < 600; y++) supportBytes[y * 800 + 220] = 1;
        ArmorBallistics.Shot nearSupport = ArmorBallistics.Trace(new ArmorBallistics.Terrain(800, 600, supportBytes),
            muzzleX, muzzleY, 700, 455, 0, 400, 0, 0);
        planningState.Units[planningState.Slot].Width = 128;
        Check(nearSupport.UsefulTerrainImpact(muzzleX, muzzleY, 700, 455) &&
            !UsableShot(planningState, nearSupport, 100, 500, 0),
            "A useful obstruction impact was allowed inside the native supporting-ground blast margin.");
        planningState.Units[planningState.Slot].Width = 24;
        foreach (ArmorBallistics.Shot refused in new[] {
            ArmorBallistics.Trace(emptyTerrain, muzzleX, muzzleY, 700, 455, 0, 400, 0, 0),
            ArmorBallistics.Trace(emptyTerrain, muzzleX, muzzleY, 700, 455, 90, 40, 0, 0, gravity: 0.01),
            ArmorBallistics.Trace(blockedTerrain, muzzleX, muzzleY, 700, 455,
                WorldAngle(planningState, digAim, dig.GunAngle, 0), dig.Shot.Power, 0, 0,
                friendlies: new[] { new ArmorBallistics.Body(dig.Shot.LandingX + 58, dig.Shot.LandingY + 24, 24, 48) }),
            selfImpact, new ArmorBallistics.Shot(100, 110, 0, 475, clear: true),
            new ArmorBallistics.Shot(39, 700, 0, 455, clear: true),
            new ArmorBallistics.Shot(401, 700, 0, 455, clear: true)
        })
            Check(!UsableShot(planningState, refused, 100, 500, 0),
                "Off-map/timeout/friendly/self-risk or out-of-range power reached firing authorization.");
        int expiredEvaluated = 0;
        Check(SearchAt(planningState, digAim, blockedTerrain, 100, 500, 0, 700, 455, 1,
            Stopwatch.StartNew(), null, ref expiredEvaluated, deadline: 0) == null && expiredEvaluated == 0,
            "An exhausted search slice still started a trajectory solve.");
        Difficulty previousDifficulty = activeDifficulty;
        try
        {
            activeDifficulty = Profiles("BotOne").Tiers["hard"];
            var moveBytes = (byte[])terrainBytes.Clone();
            for (int y = 0; y < 500; y++) moveBytes[y * 800 + 350] = y >= 300 ? (byte)1 : (byte)0;
            var moveTerrain = new ArmorBallistics.Terrain(800, 600, moveBytes);
            ShotPlan stationary = ChoosePlan(planningState, digAim, moveTerrain, 700, 455, null, false);
            Check(stationary != null && !stationary.Shot.Clear && stationary.X == 100,
                "The repositioning fixture is not blocked at its original native angle limits.");
            var moveWatch = Stopwatch.StartNew();
            ShotPlan repositioned = ChoosePlan(planningState, digAim, moveTerrain, 700, 455, null, true);
            int supportedY;
            Check(repositioned != null && repositioned.Shot.Clear && repositioned.X != 100 &&
                Math.Abs(repositioned.X - 100) <= 48 && digAim.Legal(repositioned.GunAngle) &&
                moveTerrain.Walk(100, 500, (int)repositioned.X, 12, 48, out supportedY) &&
                supportedY == repositioned.Y && moveWatch.ElapsedMilliseconds < 2000,
                "Movement did not get a bounded opportunity to replace excavation with a supported clear angle: " + Json.Serialize(repositioned));
            ShotPlan fixedReposition = ChoosePlan(planningState, digAim, moveTerrain, 700, 455, null, true, true);
            Check(fixedReposition != null && fixedReposition.Shot.Clear && fixedReposition.X != 100 &&
                fixedReposition.GunAngle == digAim.GunAngle,
                "Repositioning after a native angle clamp lost the fixed-angle clear shot.");
            Check(planningState.X == 100 && planningState.Units[planningState.Slot].X == 100 &&
                !stationary.Shot.Clear, "A predicted move was treated as an observed native position.");
            digAim.MoveRemaining = 0;
            Check(ChoosePlan(planningState, digAim, moveTerrain, 700, 455, null, true).X == 100,
                "Planning ignored exhausted native movement energy.");
            digAim.MoveRemaining = 100; movementSpent = 48;
            Check(ChoosePlan(planningState, digAim, moveTerrain, 700, 455, null, true).X == 100,
                "Planning ignored the per-turn difficulty movement allowance.");
            movementSpent = 0;
            for (int y = 500; y < 600; y++) moveBytes[y * 800 + 90] = moveBytes[y * 800 + 110] = 0;
            ShotPlan holes = ChoosePlan(planningState, digAim, moveTerrain, 700, 455, null, true);
            Check(holes != null && holes.X == 100 && !holes.Shot.Clear,
                "Excavation planning optimistically walked over an unsupported gap.");
        }
        finally { activeDifficulty = previousDifficulty; movementSpent = 0; }
        var removedBytes = (byte[])blockedBytes.Clone();
        int impactY = (int)Math.Round(dig.Shot.LandingY);
        for (int y = impactY - 8; y < impactY + 8; y++) removedBytes[y * 800 + 350] = 0;
        ArmorBallistics.TerrainChange removed = ArmorBallistics.CompareTerrain(blockedTerrain,
            new ArmorBallistics.Terrain(800, 600, removedBytes), 700, 455);
        var pending = new PendingImpact { Turn = planningState, Before = blockedTerrain, Shot = dig.Shot,
            WorldAngle = WorldAngle(planningState, digAim, dig.GunAngle, 0) };
        try
        {
            repeatedMisses = 2;
            Check(removed != null && removed.RemovedPixels == 16 && removed.NearestTargetDistance > 64 &&
                ApplyImpactFeedback(pending, removed, true) && DigFailures(planningState) == 0 && repeatedMisses == 2,
                "Observed intentional obstacle removal was learned as an ordinary missed direct shot.");
            Check(!ApplyImpactFeedback(pending, ArmorBallistics.CompareTerrain(blockedTerrain, blockedTerrain, 700, 455), false) &&
                DigFailures(planningState) == 1 && UsableShot(planningState, dig.Shot, 100, 500, 0),
                "An unobserved prediction invented excavation progress or exhausted the first retry.");
            Check(!ApplyImpactFeedback(pending, null, false) && DigFailures(planningState) == 2 &&
                !UsableShot(planningState, dig.Shot, 100, 500, 0) &&
                UsableShot(planningState, highArc.Shot, 100, 500, 0) && repeatedMisses == 2,
                "Repeated no-progress digging was unbounded or disabled safe direct shots.");
            Check(SearchAt(planningState, digAim, blockedTerrain, 100, 500, 0, 700, 455, 2,
                Stopwatch.StartNew(), null, ref evaluated) == null,
                "Replanning kept the exhausted excavation instead of withholding/pass.");
            Check(ApplyImpactFeedback(pending, removed, true) && DigFailures(planningState) == 0,
                "Actual localized terrain progress did not reset the excavation bound.");
            var distantBytes = (byte[])blockedBytes.Clone();
            for (int y = 520; y < 524; y++)
                for (int x = 650; x < 654; x++) distantBytes[y * 800 + x] = 0;
            ArmorBallistics.TerrainChange distant = ArmorBallistics.CompareTerrain(blockedTerrain,
                new ArmorBallistics.Terrain(800, 600, distantBytes), 700, 455);
            Check(!ApplyImpactFeedback(pending, distant, true) && DigFailures(planningState) == 1 &&
                !ApplyImpactFeedback(pending, removed, false) && DigFailures(planningState) == 2 && repeatedMisses == 2,
                "Distant or unattributable terrain changes were credited as excavation progress.");
            State changedTarget = SelfCheckState(SelfCheckRoom(2, slots: new[] { 1, 0 }));
            changedTarget.TargetX = 764; changedTarget.TargetY = 455;
            Check(DigFailures(changedTarget) == 0, "A changed target inherited an unrelated digging refusal.");
            var directPending = new PendingImpact { Turn = planningState, Shot = highArc.Shot, WorldAngle = 60 };
            repeatedMisses = 0;
            ApplyImpactFeedback(directPending, removed, true);
            Check(repeatedMisses == 1, "Ordinary direct-shot miss feedback was lost.");
        }
        finally { repeatedMisses = 0; excavationTarget = null; failedExcavations = 0; }
        Console.WriteLine("PASS: safe useful excavation, direct-shot priority, bounded supported/fixed-angle repositioning, exact-position replanning, measured progress and two-attempt no-progress cutoff.");
        planningState.Facing = 0;
        planningAim.GunAngle = 45; planningAim.WorldAngle = 135;
        Check(WorldAngle(planningState, planningAim, 60, 10) == 130,
            "Left-facing native world-angle or ground-slope projection changed.");
        State beforeGeometry = SelfCheckState(SelfCheckRoom(4));
        State afterGeometry = SelfCheckState(SelfCheckRoom(4));
        Check(SameShotGeometry(beforeGeometry, afterGeometry), "Identical native shot geometry was rejected.");
        afterGeometry.Units[3].X++;
        Check(!SameShotGeometry(beforeGeometry, afterGeometry), "A moving teammate did not invalidate charging safety.");
        afterGeometry = SelfCheckState(SelfCheckRoom(4));
        afterGeometry.Room.Teams[3] = 0;
        Check(!SameTurn(beforeGeometry, afterGeometry), "A team change retained turn authorization.");
        beforeGeometry.Units[3].X = beforeGeometry.X + 20;
        Check(!MoveClear(beforeGeometry, beforeGeometry.X + 12), "Movement through a living teammate was accepted.");
        Check(CanRetryShot(false, 1) && !CanRetryShot(false, 2) && !CanRetryShot(true, 0) &&
            !CanRetryShot(true, 1), "An uncertain charge can be retried or the pre-charge retry limit changed.");
        var state = new State { Mode = 11, Slot = 1, ActiveSlot = 1, Unit = 0x10000, Active = 0x10000, SelfAlive = true };
        Check(!state.MyTurn && !OtherTurn(state), "A temporary turn-flag drop can rearm a second shot.");
        state.Turn = true;
        Check(state.MyTurn && !OtherTurn(state), "The actionable own-turn guard changed.");
        state.Charge = 1;
        bool chargeRejected = false;
        try { CheckTurn(state); }
        catch (LabClient.ChargeUnavailableException) { throw new InvalidOperationException("Existing charging was marked safe to retry."); }
        catch (InvalidOperationException) { chargeRejected = true; }
        Check(chargeRejected, "Existing charging was accepted.");
        state.ActiveSlot = 0; state.Active = 0x20000;
        Check(!state.MyTurn && OtherTurn(state), "An observed opponent turn cannot rearm the controller.");
        try
        {
            RequestStop("stop-file");
            RequestStop("console-ctrl-c");
            bool chargeAttempted;
            Check(stopReason == "stop-file" && TakeTurn(0, null, null, null, out chargeAttempted) == TurnAction.None &&
                !chargeAttempted, "A cancelled turn was reported as fired, touched a client, or lost its stop reason.");
            Check(!PassTurn(0, null, null, null, null, "check"), "A stopped controller attempted to pass.");
        }
        finally { stopping = false; stopReason = null; }
        SmartCombatSelfCheck();
        Console.WriteLine("PASS: 2/4-slot named rosters, manual human Start, convergent team/Ready actions, native life/targets, friendly safety, instance/input ownership, sticky guest faults, consecutive turns/wrap and no duplicate/uncertain-charge retries.");
    }

    static bool TransientRead(Exception error)
    {
        var native = error as Win32Exception;
        return error is SnapshotBusyException || (native != null &&
            (native.NativeErrorCode == 299 || native.NativeErrorCode == 487 || native.NativeErrorCode == 998));
    }

    static object RoomDiagnostic(RoomState room, int? mode, string diagnostic = null, string observation = null)
    {
        observation = observation ?? (room == null ? "non-room" : "room");
        return new {
            Available = room != null, Observation = observation,
            Retryable = observation == "non-room" || observation == "snapshot-busy", Mode = mode,
            Game = room == null ? (uint?)null : room.Game,
            RoomId = room == null ? (int?)null : room.RoomId,
            Capacity = room == null ? (int?)null : room.Capacity,
            GameType = room == null ? (int?)null : room.GameType,
            Options = room == null ? (uint?)null : room.Options,
            SelfSlot = room == null ? (int?)null : room.SelfSlot,
            SelfName = room == null ? null : room.SelfName,
            MasterSlot = room == null ? (int?)null : room.MasterSlot,
            PlayerSlot = room == null ? (int?)null : room.PlayerSlot,
            Occupied = room == null ? (int?)null : room.Occupied,
            Names = room == null ? null : room.Names,
            States = room == null ? null : room.States,
            Teams = room == null ? null : room.Teams,
            ReadyRequested = room == null ? (bool?)null : room.ReadyRequested,
            selfReady = room == null ? (bool?)null : room.States[room.SelfSlot] == 3,
            StartBlocked = room == null ? (bool?)null : room.StartBlocked,
            InputBlocked = room == null ? (bool?)null : room.InputBlocked,
            Duel = room != null && room.Duel,
            RosterKnown = room != null && RosterIssue(room, false, false) == null,
            RosterComplete = room != null && RosterIssue(room, true, false) == null,
            completeRoster = room != null && RosterIssue(room, true, false) == null,
            TeamsBalanced = room != null && RosterIssue(room, true, true) == null,
            action = room == null ? "None" : RoomAction(room).ToString(),
            Diagnostic = diagnostic ?? (room == null ? "Not in a published native room/battle." : RoomWait(room))
        };
    }

    static object ObserveRoom(int processId)
    {
        int? mode = null;
        string diagnostic = null;
        try
        {
            using (var memory = new LabClient.MemoryReader(processId))
                for (int attempt = 0; attempt < 4; attempt++)
                    try
                    {
                        mode = memory.Int32(0x0087053C);
                        if (mode != 9 && mode != 11) return RoomDiagnostic(null, mode);
                        return RoomDiagnostic(ReadRoom(memory, mode.Value), mode);
                    }
                    catch (Exception error)
                    {
                        if (!TransientRead(error)) throw;
                        diagnostic = error.Message;
                        Thread.Sleep(5);
                    }
            return RoomDiagnostic(null, mode, diagnostic, "snapshot-busy");
        }
        catch (Exception error)
        {
            return RoomDiagnostic(null, mode, error.Message,
                TransientRead(error) ? "snapshot-busy" : "structural-error");
        }
    }

    static void DiagnosticProcessSelfCheck()
    {
        using (var singleton = new Mutex(false, SingletonName(LabClient.Root)))
        using (var self = Process.GetCurrentProcess())
        {
            Check(singleton.WaitOne(0), "Isolated diagnostic self-check singleton is already held.");
            try
            {
                using (var probe = Process.Start(new ProcessStartInfo {
                    FileName = self.MainModule.FileName, Arguments = "--room-state " + self.Id,
                    UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
                }))
                {
                    if (!probe.WaitForExit(5000))
                    {
                        probe.Kill(); probe.WaitForExit();
                        throw new InvalidOperationException("Read-only probe blocked on the controller singleton.");
                    }
                    string output = probe.StandardOutput.ReadToEnd(), error = probe.StandardError.ReadToEnd();
                    Check(probe.ExitCode == 0 && error == "", "Read-only invalid-client probe did not return structured JSON.");
                    var result = Json.Deserialize<Dictionary<string, object>>(output);
                    Check((string)result["Observation"] == "structural-error" && !(bool)result["Available"] &&
                        !(bool)result["Retryable"] && result["Capacity"] == null &&
                        ((string)result["Diagnostic"]).Contains("GunBound.gme"),
                        "Probe consulted bot credentials or bypassed native client validation.");
                }
            }
            finally { singleton.ReleaseMutex(); }
        }
        Check(Json.Serialize(RoomDiagnostic(SelfCheckRoom(2), 9)).Contains("\"Names\":[\"Player\",\"BotOne\",null") &&
            Json.Serialize(RoomDiagnostic(SelfCheckRoom(2), 9)).Contains("\"States\":[1,1,0"),
            "Native names/states no longer serialize as eight-slot arrays with null empty names.");
    }

    public static int Main(string[] args)
    {
        LabClient.SetProcessDPIAware();
        if (args.Length == 1 && args[0] == "--self-check")
        {
            Console.WriteLine(ArmorBallistics.SelfCheck());
            ControllerSelfCheck();
            if (unchecked((int)(unchecked((uint)-7) ^ 0x12345678u ^ 0x12345678u)) != -7)
                throw new InvalidOperationException("Signed wrapper-value decoding changed.");
            var profiles = Profiles("BotOne");
            var random = new Random(7);
            if (profiles.Assignments["BotOne"] != "hard" ||
                profiles.Tiers["hard"].Behavior.AimErrorDegrees != 1 ||
                profiles.Tiers["hard"].Behavior.PowerErrorUnits != 3)
                throw new InvalidOperationException("The starting hard profile requires one-degree/three-power acquisition noise.");
            for (int i = 0; i < 100; i++)
                foreach (string name in new[] { "easy", "medium", "hard" })
                    if (Math.Abs(AimError(profiles.Tiers[name], random)) > profiles.Tiers[name].Behavior.AimErrorDegrees)
                        throw new InvalidOperationException("Difficulty aim error exceeded its declared bound.");
            Check(!OwnsInput, "Self-check retained synthetic input ownership.");
            var schema = Json.Deserialize<Dictionary<string, object>>(Json.Serialize(RoomDiagnostic(SelfCheckRoom(4, 0), 9)));
            Check((int)schema["Capacity"] == 4 && (string)schema["SelfName"] == "Player" &&
                (bool)schema["RosterKnown"] && (bool)schema["RosterComplete"] && (bool)schema["completeRoster"] &&
                !(bool)schema["selfReady"] && (string)schema["action"] == "None",
                "Read-only host diagnostic schema or manual Start changed.");
            schema = Json.Deserialize<Dictionary<string, object>>(Json.Serialize(RoomDiagnostic(null, 5)));
            Check(!(bool)schema["Available"] && schema["Capacity"] == null && (bool)schema["Retryable"] &&
                (string)schema["Observation"] == "non-room", "Non-room capacity or transition semantics changed.");
            schema = Json.Deserialize<Dictionary<string, object>>(Json.Serialize(RoomDiagnostic(null, 9, "changing", "snapshot-busy")));
            Check(!(bool)schema["Available"] && schema["Capacity"] == null && (bool)schema["Retryable"] &&
                (string)schema["Observation"] == "snapshot-busy", "Snapshot-busy was reported as a structural error.");
            schema = Json.Deserialize<Dictionary<string, object>>(Json.Serialize(RoomDiagnostic(null, null, "invalid layout", "structural-error")));
            Check(!(bool)schema["Retryable"] && schema["Mode"] == null &&
                (string)schema["Observation"] == "structural-error", "Structural failure was hidden as a normal transition.");
            RoomState readyRoom = SelfCheckRoom(2);
            readyRoom.ReadyRequested = true;
            schema = Json.Deserialize<Dictionary<string, object>>(Json.Serialize(RoomDiagnostic(readyRoom, 9)));
            Check(!(bool)schema["selfReady"], "Local Ready request was presented as native confirmation.");
            readyRoom.States[readyRoom.SelfSlot] = 3;
            schema = Json.Deserialize<Dictionary<string, object>>(Json.Serialize(RoomDiagnostic(readyRoom, 9)));
            Check((bool)schema["selfReady"] && TransientRead(new SnapshotBusyException()) &&
                TransientRead(new Win32Exception(299)) && !TransientRead(new Win32Exception(5)) &&
                !TransientRead(new InvalidDataException()), "Native readiness/read-error classification changed.");
            DiagnosticProcessSelfCheck();
            Console.WriteLine("PASS: signed decoded values, three difficulty presets, hard BotOne, and read-only host room schema.");
            return 0;
        }
        if (args.Length == 2 && (args[0] == "--room-state" || args[0] == "--combat-state"))
        {
            int processId;
            if (!Int32.TryParse(args[1], out processId) || processId <= 0)
                throw new ArgumentException("A valid lab client PID is required.");
            if (args[0] == "--room-state")
            {
                Console.WriteLine(Json.Serialize(ObserveRoom(processId)));
                return 0;
            }
            LabClient.ValidateClient(processId);
            using (var memory = new LabClient.MemoryReader(processId))
            {
                if (args[0] == "--combat-state")
                {
                    State state = Stable(memory, null);
                    if (state.Mode != 11) throw new InvalidOperationException("Combat telemetry requires a live battle.");
                    AimState aim = ReadAim(memory, state);
                    ArmorBallistics.Terrain terrain = ReadTerrain(memory, state);
                    int leftY, rightY;
                    Console.WriteLine(Json.Serialize(new { state = state, aim = aim,
                        targetSelection = "nearest-living-enemy diagnostic fallback; controller-local tactical choice is in plan/target-lock/shot events",
                        terrain = new { terrain.Width, terrain.Height,
                            ownGround = terrain.Surface((int)state.X, (int)state.Y - aim.Height / 2),
                            walkLeft = terrain.Walk((int)state.X, (int)state.Y, (int)state.X - 2, aim.Width / 2, aim.Height, out leftY),
                            walkRight = terrain.Walk((int)state.X, (int)state.Y, (int)state.X + 2, aim.Width / 2, aim.Height, out rightY) } }));
                    return 0;
                }
            }
            return 0;
        }
        int? humanPid;
        int botPid;
        ParseArguments(args, out humanPid, out botPid);
        return Run(humanPid, botPid);
    }
}
