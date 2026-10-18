namespace RoyalDynamicLighting;

// Keeps SMBus calls out of the HID callback and coalesces frames to a bounded rate.
public sealed class FrameDispatcher : IDisposable
{
    private readonly object gate = new();
    private readonly AutoResetEvent changed = new(false);
    private readonly Thread thread;
    private readonly Action<RgbColor[]> send;
    private readonly Action restore;
    private readonly Action<Exception> failed;
    private readonly int interval;
    private RgbColor[]? latest;
    private bool autonomous = true;
    private bool releaseRequested;
    private bool stopping;
    private bool disposed;
    private long ownershipEpoch;

    public FrameDispatcher(Action<RgbColor[]> send, Action restore, int framesPerSecond, Action<Exception> failed)
    {
        if (framesPerSecond is < 1 or > 30) throw new ArgumentOutOfRangeException(nameof(framesPerSecond));
        this.send = send ?? throw new ArgumentNullException(nameof(send));
        this.restore = restore ?? throw new ArgumentNullException(nameof(restore));
        this.failed = failed ?? throw new ArgumentNullException(nameof(failed));
        interval = (int)Math.Ceiling(1000.0 / framesPerSecond);
        thread = new Thread(Work) { IsBackground = true, Name = "Royal RAM output" };
        thread.Start();
    }

    public void Submit(RgbColor[] frame)
    {
        ArgumentNullException.ThrowIfNull(frame);
        lock (gate)
        {
            if (stopping || autonomous) return;
            latest = (RgbColor[])frame.Clone();
            changed.Set();
        }
    }

    public void SetAutonomous(bool value)
    {
        lock (gate)
        {
            if (stopping || autonomous == value) return;
            if (value) releaseRequested = true;
            ownershipEpoch++;
            autonomous = value;
            latest = null;
            changed.Set();
        }
    }

    private void Work()
    {
        try
        {
            long nextFrameAt = 0;
            while (true)
            {
                changed.WaitOne();
                while (true)
                {
                    RgbColor[]? frame;
                    bool release;
                    long epoch;
                    lock (gate)
                    {
                        if (stopping) return;
                        release = releaseRequested;
                        epoch = ownershipEpoch;
                        releaseRequested = false;
                        frame = autonomous ? null : latest;
                        latest = null;
                    }
                    if (release) restore();
                    if (frame is null) break;
                    int delay = (int)Math.Max(0, nextFrameAt - Environment.TickCount64);
                    if (delay > 0)
                    {
                        // Return the frame only if a newer frame has not superseded it.
                        lock (gate) { if (!stopping && !autonomous && ownershipEpoch == epoch && latest is null) latest = frame; }
                        changed.WaitOne(delay);
                        continue;
                    }
                    lock (gate)
                    {
                        if (stopping || autonomous || ownershipEpoch != epoch) continue;
                    }
                    // A transaction already started may finish during a handover;
                    // pending frames from an older ownership interval are discarded.
                    send(frame);
                    nextFrameAt = Environment.TickCount64 + interval;
                }
            }
        }
        catch (Exception ex) { ReportFailure(ex); }
        finally
        {
            try { restore(); }
            catch (Exception ex) { ReportFailure(ex); }
        }
    }

    public void Dispose()
    {
        if (Thread.CurrentThread == thread) throw new InvalidOperationException("Dispose must run outside the RAM output thread.");
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            stopping = true;
            changed.Set();
        }
        thread.Join();
        changed.Dispose();
    }

    private void ReportFailure(Exception exception)
    {
        try { failed(exception); }
        catch { /* A diagnostic callback must not terminate the process. */ }
    }
}
