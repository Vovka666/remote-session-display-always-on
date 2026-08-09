<#
    Display topology, read and written through the CCD API.

    This is the only trustworthy view of what Windows is actually driving.
    EnumDisplayDevices lies in clone mode: with several monitors showing the
    same picture there is exactly ONE active source, and it reports itself as
    "Generic Non-PnP Monitor" - which reads as "the virtual display is broken"
    when nothing is wrong at all. QueryDisplayConfig enumerates every target
    and tells the truth.

    DisplaySwitch.exe /clone is likewise unusable here: it duplicates onto
    everything, including the laptop panel you were trying to leave dark. An
    exact clone can only be built by handing SetDisplayConfig the precise set
    of paths to keep.

    Everything in this file is deliberately plain ASCII. Windows PowerShell 5.1
    reads a .ps1 without a byte-order mark using the system code page, so a
    stray em dash in a Russian or Greek locale turns into three bytes, one of
    which happens to be a quote character, and the script stops parsing.
#>

Add-Type -ErrorAction Stop @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class VigilCcd
{
    // ---- CCD structures ----------------------------------------------------
    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] public struct RATIONAL { public uint Num; public uint Den; }

    [StructLayout(LayoutKind.Sequential)]
    public struct SOURCE { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }

    [StructLayout(LayoutKind.Sequential)]
    public struct TARGET {
        public LUID adapterId; public uint id; public uint modeInfoIdx;
        public uint outputTechnology; public uint rotation; public uint scaling;
        public RATIONAL refreshRate; public uint scanLineOrdering;
        public int targetAvailable; public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH { public SOURCE src; public TARGET tgt; public uint flags; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MODE {
        public uint infoType; public uint id; public LUID adapterId;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 48)] public byte[] blob;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HEADER { public uint type; public uint size; public LUID adapterId; public uint id; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct TARGET_NAME {
        public HEADER header; public uint flags; public uint outputTechnology;
        public ushort edidManufactureId; public ushort edidProductCodeId; public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]  public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string monitorDevicePath;
    }

    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint np, out uint nm);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint np, [Out] PATH[] paths, ref uint nm, [Out] MODE[] modes, IntPtr topo);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref TARGET_NAME req);
    [DllImport("user32.dll")] static extern int SetDisplayConfig(uint np, PATH[] paths, uint nm, MODE[] modes, uint flags);

    const uint QDC_ALL_PATHS         = 1;
    const uint QDC_ONLY_ACTIVE_PATHS = 2;

    const uint DISPLAYCONFIG_PATH_ACTIVE = 0x1;
    const uint MODE_INFO_TYPE_SOURCE     = 1;
    const uint INVALID_MODE_INDEX        = 0xFFFFFFFF;

    // SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_SAVE_TO_DATABASE | SDC_ALLOW_CHANGES
    const uint SDC_FLAGS = 0x80 | 0x20 | 0x200 | 0x400;

    // Same, without SDC_ALLOW_CHANGES: take the supplied modes or fail, rather
    // than silently substituting something safer and smaller.
    const uint SDC_FLAGS_EXACT = 0x80 | 0x20 | 0x200;

    /// One display target: a physical connector, or a virtual one.
    public class Target
    {
        public string DevicePath;
        public string FriendlyName;
        public bool   Active;
        public uint   SourceId;
        public uint   TargetId;
        public string AdapterId;      // targets on different adapters cannot share a source
        public uint   OutputTechnology;
        public int    Width;
        public int    Height;
        public double RefreshHz;

        public string Describe()
        {
            string name = string.IsNullOrEmpty(FriendlyName) ? "(no EDID name)" : FriendlyName;
            string mode = (Width > 0) ? (Width + "x" + Height) : "-";
            return name + "  " + mode + "  " + DevicePath;
        }
    }

    static string NameOf(PATH p, out string friendly)
    {
        TARGET_NAME tn = new TARGET_NAME();
        tn.header.type = 2;                                   // GET_TARGET_NAME
        tn.header.size = (uint)Marshal.SizeOf(typeof(TARGET_NAME));
        tn.header.adapterId = p.tgt.adapterId;
        tn.header.id = p.tgt.id;
        if (DisplayConfigGetDeviceInfo(ref tn) != 0) { friendly = ""; return ""; }
        friendly = tn.monitorFriendlyDeviceName;
        return tn.monitorDevicePath;
    }

    /// Every target Windows knows about. activeOnly narrows it to what is lit.
    public static Target[] Query(bool activeOnly)
    {
        uint flags = activeOnly ? QDC_ONLY_ACTIVE_PATHS : QDC_ALL_PATHS;
        uint np, nm;
        if (GetDisplayConfigBufferSizes(flags, out np, out nm) != 0) return new Target[0];

        PATH[] paths = new PATH[np];
        MODE[] modes = new MODE[nm];
        if (QueryDisplayConfig(flags, ref np, paths, ref nm, modes, IntPtr.Zero) != 0) return new Target[0];

        List<Target> found = new List<Target>();
        for (int i = 0; i < np; i++)
        {
            string friendly;
            string path = NameOf(paths[i], out friendly);
            if (string.IsNullOrEmpty(path)) continue;

            Target t = new Target();
            t.DevicePath = path;
            t.FriendlyName = friendly;
            t.Active = (paths[i].flags & DISPLAYCONFIG_PATH_ACTIVE) != 0;
            t.SourceId = paths[i].src.id;
            t.TargetId = paths[i].tgt.id;
            t.AdapterId = paths[i].tgt.adapterId.High + ":" + paths[i].tgt.adapterId.Low;
            t.OutputTechnology = paths[i].tgt.outputTechnology;
            if (paths[i].tgt.refreshRate.Den != 0)
                t.RefreshHz = Math.Round((double)paths[i].tgt.refreshRate.Num / paths[i].tgt.refreshRate.Den, 1);

            // Resolution lives in the source mode, as the first two DWORDs of
            // the mode union.
            uint idx = paths[i].src.modeInfoIdx;
            if (idx != INVALID_MODE_INDEX && idx < nm && modes[idx].infoType == MODE_INFO_TYPE_SOURCE)
            {
                t.Width  = BitConverter.ToInt32(modes[idx].blob, 0);
                t.Height = BitConverter.ToInt32(modes[idx].blob, 4);
            }
            found.Add(t);
        }
        return found.ToArray();
    }

    /// Ask Windows to build a topology itself, from everything connected.
    ///
    /// Needed because Apply() can only work with paths that are already active:
    /// a display that has been switched off stops appearing there, so no amount
    /// of filtering will bring it back. Handing Windows a hand-built path for
    /// an inactive target is how you earn ERROR_INVALID_PARAMETER; letting it
    /// construct the arrangement is reliable.
    ///
    /// topology: 1 = internal, 2 = clone, 4 = extend, 8 = external.
    public static int ApplyPreset(uint topology)
    {
        const uint SDC_APPLY = 0x80;
        return SetDisplayConfig(0, null, 0, null, topology | SDC_APPLY);
    }

    /// Rebuild the active topology from the targets that match none of drop.
    ///
    /// mode 0 (preserve) keeps each target on the source Windows already gave
    /// it, dropping only what was excluded. This is the mode that works
    /// everywhere, and the default.
    ///
    /// mode 1 (clone) additionally points every kept target at one shared
    /// source. A source belongs to one graphics adapter, so this is only valid
    /// while all kept targets are on the same adapter - on a laptop with an
    /// iGPU, a discrete GPU and a virtual display driver they rarely are, and
    /// asking for it anyway earns ERROR_INVALID_PARAMETER (87). Rather than
    /// fail, Vigil falls back to preserve and says so in the report.
    ///
    /// Returns the Win32 result; -999 means the request was refused because it
    /// would have left the machine with no picture at all.
    public static int Apply(string[] drop, int mode, out string report)
    {
        report = "";
        uint np, nm;
        int rc = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out np, out nm);
        if (rc != 0) { report = "GetDisplayConfigBufferSizes failed"; return rc; }

        PATH[] paths = new PATH[np];
        MODE[] modes = new MODE[nm];
        rc = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref np, paths, ref nm, modes, IntPtr.Zero);
        if (rc != 0) { report = "QueryDisplayConfig failed"; return rc; }

        List<PATH> keep = new List<PATH>();
        for (int i = 0; i < np; i++)
        {
            string friendly;
            string path = NameOf(paths[i], out friendly);
            string haystack = path + " | " + friendly;

            bool skip = false;
            if (drop != null)
                foreach (string d in drop)
                    if (!string.IsNullOrEmpty(d) &&
                        haystack.IndexOf(d, StringComparison.OrdinalIgnoreCase) >= 0) skip = true;

            report += (skip ? "  DROP  " : "  KEEP  ") + haystack + "\n";
            if (skip) continue;
            keep.Add(paths[i]);
        }

        if (keep.Count == 0)
        {
            report += "refusing: that would leave no active display at all";
            return -999;
        }

        if (mode == 1)
        {
            bool sameAdapter = true;
            LUID first = keep[0].tgt.adapterId;
            foreach (PATH p in keep)
                if (p.tgt.adapterId.Low != first.Low || p.tgt.adapterId.High != first.High)
                    sameAdapter = false;

            if (sameAdapter)
            {
                SOURCE shared = keep[0].src;
                for (int i = 0; i < keep.Count; i++)
                {
                    PATH p = keep[i];
                    p.src = shared;                  // one source, many targets
                    keep[i] = p;
                }
            }
            else
            {
                report += "  NOTE  kept displays span several graphics adapters, " +
                          "so a shared-source clone is not possible; keeping the " +
                          "current arrangement instead\n";
            }
        }

        // First attempt: hand back the modes Windows is already using, so every
        // kept display stays at the resolution it has. Blanking the mode
        // indices and letting Windows re-derive them looks harmless and is not
        // - it re-picks conservatively, and a 2560x1440 monitor cloned with a
        // virtual one lands on 1024x768. Once saved to the database that
        // choice comes back on every reconnect.
        List<PATH> exact = new List<PATH>();
        foreach (PATH p in keep)
        {
            PATH q = p;
            q.flags |= DISPLAYCONFIG_PATH_ACTIVE;
            exact.Add(q);
        }

        int rc2 = SetDisplayConfig((uint)exact.Count, exact.ToArray(), nm, modes, SDC_FLAGS_EXACT);
        if (rc2 == 0)
        {
            report += "  MODE  kept current resolutions\n";
            return 0;
        }

        // Fallback: the hardware would not take that arrangement at those
        // modes, so let Windows choose. Reported, because a resolution may
        // change and the user should be able to see why.
        report += "  MODE  exact modes refused (rc=" + rc2 + "), letting Windows choose\n";
        for (int i = 0; i < keep.Count; i++)
        {
            PATH p = keep[i];
            p.src.modeInfoIdx = INVALID_MODE_INDEX;
            p.tgt.modeInfoIdx = INVALID_MODE_INDEX;
            p.flags |= DISPLAYCONFIG_PATH_ACTIVE;
            keep[i] = p;
        }

        return SetDisplayConfig((uint)keep.Count, keep.ToArray(), 0, null, SDC_FLAGS);
    }
}
'@

function Get-VigilTarget {
    <#
    .SYNOPSIS
        Display targets as Windows sees them. The authoritative view.
    .DESCRIPTION
        Without -ActiveOnly this includes every path Windows remembers, so one
        physical monitor can appear several times with different source and
        target pairings. Callers showing this to a person should collapse it by
        device path.
    #>
    [CmdletBinding()]
    param([switch] $ActiveOnly)

    [VigilCcd]::Query([bool]$ActiveOnly)
}

function Expand-VigilTopology {
    <#
    .SYNOPSIS
        Let Windows light everything that is connected.
    .DESCRIPTION
        Used to recover a display that is attached as a device but has no
        active path - a state Set-VigilTopology cannot fix, because it only
        ever sees paths that are already active. Exclusions are applied
        afterwards, so this is a step on the way rather than the final
        arrangement.
    #>
    [CmdletBinding()]
    param([ValidateSet('extend', 'clone')] [string] $As = 'extend')

    $flag = $(if ($As -eq 'clone') { 2 } else { 4 })
    $rc = [VigilCcd]::ApplyPreset($flag)
    [pscustomobject]@{ ResultCode = $rc; Succeeded = ($rc -eq 0) }
}

function Set-VigilTopology {
    <#
    .SYNOPSIS
        Rebuild the active topology, keeping everything that does not match one
        of the -Exclude patterns.
    .PARAMETER Mode
        preserve - keep the arrangement Windows already has, minus the excluded
                   displays. Works on every machine, and is the default.
        clone    - additionally point every kept display at one source, so they
                   all show the same desktop. Only possible while they are on
                   one graphics adapter; otherwise Vigil keeps the current
                   arrangement and says so.
    #>
    [CmdletBinding()]
    param(
        [string[]] $Exclude = @(),
        [ValidateSet('preserve', 'clone')] [string] $Mode = 'preserve'
    )

    $report = ''
    $rc = [VigilCcd]::Apply($Exclude, $(if ($Mode -eq 'clone') { 1 } else { 0 }), [ref]$report)

    # 87 is ERROR_INVALID_PARAMETER: the supplied topology was not something
    # this hardware can be put into. Named here because a bare number sends
    # people looking in the wrong place.
    $meaning = ''
    switch ($rc) {
        0     { $meaning = 'applied' }
        5     { $meaning = 'access denied - needs elevation' }
        87    { $meaning = 'invalid parameter - this arrangement is not possible on this hardware' }
        -999  { $meaning = 'refused - would have left no active display' }
        default { $meaning = "win32 error $rc" }
    }

    [pscustomobject]@{
        Mode       = $Mode
        ResultCode = $rc
        Succeeded  = ($rc -eq 0)
        Meaning    = $meaning
        Report     = $report.TrimEnd()
    }
}
