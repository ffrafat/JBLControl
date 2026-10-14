using JBLControl.Windows;

Console.WriteLine("JBLControl.Windows — Phase 2 BLE harness (console only; the real UI lands in Phase 4).");

var manager = new SpeakerManager();
var stop = new TaskCompletionSource();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    stop.TrySetResult();
};

manager.Start();
await stop.Task;

Console.WriteLine("Stopping...");
await manager.DisposeAsync();
