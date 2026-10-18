using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using RoyalDynamicLighting;

namespace RoyalDynamicLighting.Tests;

public static class FrameDispatcherTests
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);

    public static void Run()
    {
        LampReportsReachTheWorkerAndReleaseRestoresState();
        BusyOutputCoalescesFramesAndHonorsTheRate();
        OwnershipChangesCannotReplayAFrameAfterRestoration();
        AFailedSendStillRestoresAndReportsTheError();
        AFailedReleaseStillAttemptsFinalRestoration();
        ErrorNotificationFailuresCannotPreventRestoration();
        DisposeStopsOutputAndIsIdempotent();
        Console.WriteLine("FrameDispatcher: 7 pipeline and lifecycle checks passed.");
    }

    private static void LampReportsReachTheWorkerAndReleaseRestoresState()
    {
        using var sent = new ManualResetEventSlim();
        using var restored = new ManualResetEventSlim();
        var errors = new ConcurrentQueue<Exception>();
        RgbColor[] original = [new(1, 2, 3), new(4, 5, 6)];
        RgbColor[] physical = (RgbColor[])original.Clone();
        int sends = 0, restores = 0, outputThread = 0;
        var lamp = new LampArray(2);
        using var dispatcher = new FrameDispatcher(frame =>
        {
            physical = frame;
            outputThread = Environment.CurrentManagedThreadId;
            Interlocked.Increment(ref sends);
            sent.Set();
        }, () =>
        {
            physical = (RgbColor[])original.Clone();
            Interlocked.Increment(ref restores);
            restored.Set();
        }, 30, errors.Enqueue);
        lamp.FrameReady += dispatcher.Submit;
        lamp.AutonomousModeChanged += dispatcher.SetAutonomous;

        lamp.SetFeature(Range(0, 1, 255, 0, 0, 255, true));
        Equal(0, Volatile.Read(ref sends), "autonomous reports cannot reach hardware");
        lamp.SetFeature(new byte[] { 6, 0 });
        lamp.SetFeature(Range(0, 0, 255, 100, 0, 128, false));
        Equal(0, Volatile.Read(ref sends), "incomplete frame cannot reach hardware");
        lamp.SetFeature(Range(1, 1, 20, 30, 40, 255, true));
        Wait(sent, "completed frame reaches worker");
        Equal(new RgbColor(128, 50, 0), physical[0], "brightness reaches hardware");
        Equal(new RgbColor(20, 30, 40), physical[1], "batched second lamp reaches hardware");
        True(outputThread != Environment.CurrentManagedThreadId, "hardware work runs outside HID callback thread");
        lamp.SetFeature(new byte[] { 6, 1 });
        Wait(restored, "ownership release restores hardware");
        True(physical.SequenceEqual(original), "original physical colors restored");
        Equal(1, Volatile.Read(ref sends), "ownership release does not send another frame");
        True(errors.IsEmpty, "successful pipeline has no errors");
        dispatcher.Dispose();
        True(physical.SequenceEqual(original), "shutdown preserves restored colors");
        True(restores >= 1, "restoration occurred");
    }

    private static void BusyOutputCoalescesFramesAndHonorsTheRate()
    {
        using var firstEntered = new ManualResetEventSlim();
        using var allowFirst = new ManualResetEventSlim();
        using var secondEntered = new ManualResetEventSlim();
        var frames = new ConcurrentQueue<RgbColor[]>();
        var errors = new ConcurrentQueue<Exception>();
        int count = 0;
        long firstFinished = 0, secondStarted = 0;
        using var dispatcher = new FrameDispatcher(frame =>
        {
            frames.Enqueue(frame);
            if (Interlocked.Increment(ref count) == 1)
            {
                firstEntered.Set();
                Wait(allowFirst, "release blocked first send");
                firstFinished = Stopwatch.GetTimestamp();
            }
            else
            {
                secondStarted = Stopwatch.GetTimestamp();
                secondEntered.Set();
            }
        }, () => { }, 30, errors.Enqueue);
        try
        {
            dispatcher.SetAutonomous(false);
            dispatcher.Submit([new(1, 0, 0)]);
            Wait(firstEntered, "first send starts");
            dispatcher.Submit([new(2, 0, 0)]);
            RgbColor[] newest = [new(3, 0, 0)];
            dispatcher.Submit(newest);
            newest[0] = new(255, 255, 255);
            allowFirst.Set();
            Wait(secondEntered, "coalesced send starts");
            dispatcher.Dispose();
            Equal(2, frames.Count, "only first and newest frames sent");
            Equal(new RgbColor(3, 0, 0), frames.ToArray()[1][0], "newest frame retained with copied input ownership");
            // The dispatcher uses integer milliseconds (34 ms at 30 FPS). Allow
            // only a small clock sampling margin; scheduler delays increase time.
            True(Stopwatch.GetElapsedTime(firstFinished, secondStarted) >= TimeSpan.FromMilliseconds(30), "output rate is bounded after completion of preceding send");
            True(errors.IsEmpty, "coalescing has no errors");
        }
        finally { allowFirst.Set(); }
    }

    private static void OwnershipChangesCannotReplayAFrameAfterRestoration()
    {
        using var firstEntered = new ManualResetEventSlim();
        using var allowFirst = new ManualResetEventSlim();
        using var restoreEntered = new ManualResetEventSlim();
        using var allowRestore = new ManualResetEventSlim();
        using var secondRestoreEntered = new ManualResetEventSlim();
        using var allowSecondRestore = new ManualResetEventSlim();
        using var thirdFrameSent = new ManualResetEventSlim();
        var frames = new ConcurrentQueue<RgbColor[]>();
        var errors = new ConcurrentQueue<Exception>();
        int sends = 0, restores = 0;
        using var dispatcher = new FrameDispatcher(frame =>
        {
            frames.Enqueue(frame);
            if (Interlocked.Increment(ref sends) == 1)
            {
                firstEntered.Set();
                Wait(allowFirst, "release first ownership frame");
            }
            if (frame[0].R == 3) thirdFrameSent.Set();
        }, () =>
        {
            int n = Interlocked.Increment(ref restores);
            if (n == 1)
            {
                restoreEntered.Set();
                Wait(allowRestore, "release first restoration");
            }
            else if (n == 2)
            {
                secondRestoreEntered.Set();
                Wait(allowSecondRestore, "release second restoration");
            }
        }, 30, errors.Enqueue);
        try
        {
            dispatcher.SetAutonomous(false);
            dispatcher.Submit([new(1, 0, 0)]);
            Wait(firstEntered, "first ownership send starts");
            dispatcher.SetAutonomous(true);
            dispatcher.SetAutonomous(false);
            dispatcher.Submit([new(2, 0, 0)]);
            allowFirst.Set();
            Wait(restoreEntered, "release preserved despite immediate reacquisition");

            // The worker has extracted frame 2 and is blocked in restoration.
            // A new ownership interval must invalidate that extracted frame.
            dispatcher.SetAutonomous(true);
            dispatcher.SetAutonomous(false);
            // Ensure the frame rate delay is over before releasing restoration,
            // making the stale-frame race deterministic rather than scheduler-dependent.
            using (var timer = new ManualResetEventSlim()) timer.Wait(TimeSpan.FromMilliseconds(75));
            allowRestore.Set();
            Wait(secondRestoreEntered, "second ownership release is never lost");
            Equal(1, Volatile.Read(ref sends), "frame from previous owner cannot replay after restore");
            dispatcher.Submit([new(3, 0, 0)]);
            allowSecondRestore.Set();
            Wait(thirdFrameSent, "new ownership frame reaches hardware");
            dispatcher.Dispose();
            True(frames.Select(f => f[0].R).SequenceEqual(new byte[] { 1, 3 }), "only current ownership frames emitted");
            True(errors.IsEmpty, "ownership transitions have no errors");
        }
        finally
        {
            allowFirst.Set();
            allowRestore.Set();
            allowSecondRestore.Set();
        }
    }

    private static void AFailedSendStillRestoresAndReportsTheError()
    {
        using var restored = new ManualResetEventSlim();
        var errors = new ConcurrentQueue<Exception>();
        var error = new IOException("Simulated RAM send failure");
        int sends = 0, restores = 0;
        using var dispatcher = new FrameDispatcher(_ =>
        {
            Interlocked.Increment(ref sends);
            throw error;
        }, () =>
        {
            Interlocked.Increment(ref restores);
            restored.Set();
        }, 30, errors.Enqueue);
        dispatcher.SetAutonomous(false);
        dispatcher.Submit([new(1, 2, 3)]);
        Wait(restored, "send failure triggers restoration");
        dispatcher.Dispose();
        Equal(1, sends, "failed send attempted once");
        Equal(1, restores, "failure cleanup restores once");
        True(errors.TryDequeue(out var actual) && ReferenceEquals(error, actual), "original send exception reported");
        True(errors.IsEmpty, "no duplicate failure notification");
    }

    private static void ErrorNotificationFailuresCannotPreventRestoration()
    {
        using var restored = new ManualResetEventSlim();
        int notifications = 0;
        using var dispatcher = new FrameDispatcher(_ => throw new IOException("send failure"),
            () => restored.Set(), 30, _ =>
            {
                Interlocked.Increment(ref notifications);
                throw new InvalidOperationException("notification consumer failed");
            });
        dispatcher.SetAutonomous(false);
        dispatcher.Submit([new(1, 2, 3)]);
        Wait(restored, "failed error notification cannot suppress cleanup");
        dispatcher.Dispose();
        Equal(1, notifications, "error consumer invoked once");
    }

    private static void AFailedReleaseStillAttemptsFinalRestoration()
    {
        using var finalFailureReported = new ManualResetEventSlim();
        var errors = new ConcurrentQueue<Exception>();
        int restores = 0;
        using var dispatcher = new FrameDispatcher(_ => { }, () =>
        {
            Interlocked.Increment(ref restores);
            throw new IOException("Simulated RAM restoration failure");
        }, 30, error =>
        {
            errors.Enqueue(error);
            if (errors.Count == 2) finalFailureReported.Set();
        });
        dispatcher.SetAutonomous(false);
        dispatcher.SetAutonomous(true);
        Wait(finalFailureReported, "both failed release and final cleanup are reported");
        dispatcher.Dispose();
        Equal(2, restores, "release failure still attempts final restoration");
        Equal(2, errors.Count, "both restoration failures are visible");
    }

    private static void DisposeStopsOutputAndIsIdempotent()
    {
        int sends = 0, restores = 0;
        var errors = new ConcurrentQueue<Exception>();
        var dispatcher = new FrameDispatcher(_ => Interlocked.Increment(ref sends),
            () => Interlocked.Increment(ref restores), 30, errors.Enqueue);
        dispatcher.Dispose();
        dispatcher.Dispose();
        dispatcher.SetAutonomous(false);
        dispatcher.Submit([new(1, 2, 3)]);
        Equal(0, sends, "disposed worker cannot send");
        Equal(1, restores, "dispose performs final restoration once");
        True(errors.IsEmpty, "clean disposal has no errors");
    }

    private static byte[] Range(ushort first, ushort last, byte red, byte green, byte blue, byte intensity, bool complete) =>
    [5, complete ? (byte)1 : (byte)0, (byte)first, (byte)(first >> 8), (byte)last, (byte)(last >> 8), red, green, blue, intensity];

    private static void Wait(ManualResetEventSlim signal, string message)
    {
        if (!signal.Wait(Timeout)) throw new InvalidOperationException($"Timed out: {message}");
    }

    private static void Equal<T>(T expected, T actual, string message)
    {
        if (!Equals(expected, actual)) throw new InvalidOperationException($"{message}: expected {expected}, got {actual}");
    }

    private static void True(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
