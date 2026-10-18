using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;

namespace RoyalDynamicLighting.Installation
{
    // Read-only Authenticode validation. In particular, this never trusts a
    // certificate, changes a certificate store, displays UI, or fetches URLs.
    public static class Authenticode
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInfo
        {
            public uint Size;
            public IntPtr Path;
            public IntPtr Handle;
            public IntPtr KnownSubject;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct TrustData
        {
            public uint Size;
            public IntPtr PolicyCallbackData;
            public IntPtr SipClientData;
            public uint UiChoice;
            public uint RevocationChecks;
            public uint UnionChoice;
            public IntPtr File;
            public uint StateAction;
            public IntPtr StateData;
            public IntPtr UrlReference;
            public uint ProviderFlags;
            public uint UiContext;
            public IntPtr SignatureSettings;
        }

        public sealed class Result
        {
            public uint HResult { get; internal set; }
            public string SignerThumbprint { get; internal set; }
            public bool AcceptableBeforeTrust
            {
                get { return HResult == 0 || HResult == 0x800B0109U; }
            }
        }

        [DllImport("wintrust.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
        private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);

        public static Result VerifyFile(string path)
        {
            path = System.IO.Path.GetFullPath(path);
            var action = new Guid("00AAC56B-CD44-11D0-8CC2-00C04FC295EE"); // GENERIC_VERIFY_V2
            IntPtr pathBuffer = IntPtr.Zero;
            IntPtr fileBuffer = IntPtr.Zero;
            var trust = new TrustData();
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                try
                {
                    pathBuffer = Marshal.StringToHGlobalUni(path);
                    var file = new FileInfo
                    {
                        Size = (uint)Marshal.SizeOf(typeof(FileInfo)),
                        Path = pathBuffer,
                        Handle = stream.SafeFileHandle.DangerousGetHandle()
                    };
                    fileBuffer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(FileInfo)));
                    Marshal.StructureToPtr(file, fileBuffer, false);
                    trust.Size = (uint)Marshal.SizeOf(typeof(TrustData));
                    trust.UiChoice = 2; // WTD_UI_NONE
                    trust.UnionChoice = 1; // WTD_CHOICE_FILE
                    trust.File = fileBuffer;
                    trust.StateAction = 1; // WTD_STATEACTION_VERIFY
                    // The package has a locally generated self-signed leaf with
                    // no revocation endpoint. Perform local validation only.
                    trust.ProviderFlags = 0x1000 | 0x10; // CACHE_ONLY_URL_RETRIEVAL | REVOCATION_CHECK_NONE
                    var result = new Result
                    {
                        HResult = unchecked((uint)WinVerifyTrust(new IntPtr(-1), ref action, ref trust))
                    };
                    if (result.AcceptableBeforeTrust)
                    {
                        using (var signer = X509Certificate.CreateFromSignedFile(path))
                            result.SignerThumbprint = signer.GetCertHashString();
                    }
                    return result;
                }
                finally
                {
                    if (trust.StateData != IntPtr.Zero)
                    {
                        trust.StateAction = 2; // WTD_STATEACTION_CLOSE
                        WinVerifyTrust(new IntPtr(-1), ref action, ref trust);
                    }
                    if (fileBuffer != IntPtr.Zero) Marshal.FreeHGlobal(fileBuffer);
                    if (pathBuffer != IntPtr.Zero) Marshal.FreeHGlobal(pathBuffer);
                }
            }
        }
    }
}
