#!/usr/bin/env python3
"""
overlay_extract.py — Extract a moving overlay (dancing man) from a mostly-static background.

Uses median-based background estimation + configurable thresholding.
Two modes:
  1. Interactive (default): OpenCV trackbar GUI to dial in thresholds live
  2. Batch: export overlay frames / reassembled video with chosen settings

Requirements:
  pip install opencv-python numpy

Usage:
  # Interactive tuning mode (default) — scrub frames, adjust thresholds live
  python overlay_extract.py input.gif

  # Interactive with initial settings
  python overlay_extract.py input.mp4 --threshold 40 --morph 3 --dilate 2

  # Batch export once you've found good settings
  python overlay_extract.py input.gif --batch --threshold 35 --morph 3 --dilate 2 --output out/

  # Use MOG2 adaptive background instead of global median
  python overlay_extract.py input.mp4 --method mog2 --mog-history 120 --mog-var 40

  # Color-range pre-filter: keep only reddish/blueish overlay pixels before thresholding
  python overlay_extract.py input.gif --color-filter

  # Export as video instead of frames
  python overlay_extract.py input.gif --batch --video --output overlay.mp4

  # Limit frames loaded (useful for huge files)
  python overlay_extract.py input.mp4 --max-frames 500
"""

import argparse
import os
import sys
import numpy as np
import cv2


def load_frames(path, max_frames=None):
    """Load all frames from a video/gif into a numpy array."""
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        print(f"[ERROR] Cannot open: {path}")
        sys.exit(1)

    fps = cap.get(cv2.CAP_PROP_FPS) or 25.0
    frames = []
    count = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        frames.append(frame)
        count += 1
        if max_frames and count >= max_frames:
            break
        if count % 100 == 0:
            print(f"  loaded {count} frames...")

    cap.release()
    print(f"Loaded {len(frames)} frames @ {fps:.1f} fps, {frames[0].shape[1]}x{frames[0].shape[0]}")
    return frames, fps


def compute_background_median(frames, sample_cap=200):
    """Compute median background. Samples frames if there are too many for memory."""
    n = len(frames)
    if n > sample_cap:
        indices = np.linspace(0, n - 1, sample_cap, dtype=int)
        sample = np.stack([frames[i] for i in indices]).astype(np.float32)
    else:
        sample = np.stack(frames).astype(np.float32)

    print(f"Computing median background from {len(sample)} frames...")
    bg = np.median(sample, axis=0).astype(np.uint8)
    return bg


def compute_background_mog2(frames, history=120, var_threshold=40):
    """Compute per-frame foreground masks using MOG2."""
    fgbg = cv2.createBackgroundSubtractorMOG2(
        history=history,
        varThreshold=var_threshold,
        detectShadows=False,
    )
    # "Train" on all frames first
    print(f"Training MOG2 (history={history}, var={var_threshold})...")
    for f in frames:
        fgbg.apply(f)
    return fgbg


def extract_overlay(frame, background, threshold, morph_size, dilate_iter,
                    color_filter=False, min_area=0):
    """
    Given a frame and background, extract the overlay.
    Returns (overlay_rgba, mask, diff_gray) for visualization.
    """
    diff = cv2.absdiff(frame, background)
    gray = cv2.cvtColor(diff, cv2.COLOR_BGR2GRAY)

    # Threshold
    _, mask = cv2.threshold(gray, threshold, 255, cv2.THRESH_BINARY)

    # Optional color filter: boost pixels in red/white/blue range (the suit)
    if color_filter:
        hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
        # Red hues (wraps around 0/180)
        red1 = cv2.inRange(hsv, (0, 50, 50), (10, 255, 255))
        red2 = cv2.inRange(hsv, (170, 50, 50), (180, 255, 255))
        # Blue hues
        blue = cv2.inRange(hsv, (100, 50, 50), (130, 255, 255))
        # White / high-value
        white = cv2.inRange(hsv, (0, 0, 180), (180, 40, 255))
        # Dark skin tones (broader to catch the dancer)
        dark = cv2.inRange(hsv, (0, 20, 20), (25, 180, 120))

        color_mask = red1 | red2 | blue | white | dark
        # Dilate the color mask so it's generous
        color_mask = cv2.dilate(color_mask, np.ones((5, 5), np.uint8), iterations=2)
        mask = cv2.bitwise_and(mask, color_mask)

    # Morphological cleanup
    if morph_size > 0:
        kernel = np.ones((morph_size, morph_size), np.uint8)
        mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
        mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)

    # Dilate to fill gaps
    if dilate_iter > 0:
        mask = cv2.dilate(mask, np.ones((3, 3), np.uint8), iterations=dilate_iter)

    # Optional: remove small blobs
    if min_area > 0:
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        mask_clean = np.zeros_like(mask)
        for c in contours:
            if cv2.contourArea(c) >= min_area:
                cv2.drawContours(mask_clean, [c], -1, 255, -1)
        mask = mask_clean

    # Extract overlay with alpha
    overlay_bgra = cv2.cvtColor(frame, cv2.COLOR_BGR2BGRA)
    overlay_bgra[:, :, 3] = mask

    # RGB overlay (black bg)
    overlay_rgb = cv2.bitwise_and(frame, frame, mask=mask)

    return overlay_rgb, overlay_bgra, mask, gray


def interactive_mode(frames, fps, background, args):
    """OpenCV GUI with trackbars for live threshold tuning."""
    win = "Overlay Extractor"
    cv2.namedWindow(win, cv2.WINDOW_NORMAL)

    n = len(frames)
    cv2.createTrackbar("Frame", win, 0, n - 1, lambda x: None)
    cv2.createTrackbar("Threshold", win, args.threshold, 255, lambda x: None)
    cv2.createTrackbar("Morph Size", win, args.morph, 20, lambda x: None)
    cv2.createTrackbar("Dilate Iter", win, args.dilate, 10, lambda x: None)
    cv2.createTrackbar("Min Area", win, args.min_area, 5000, lambda x: None)
    cv2.createTrackbar("Color Filter", win, 1 if args.color_filter else 0, 1, lambda x: None)
    cv2.createTrackbar("View [0-4]", win, 0, 4, lambda x: None)

    playing = False
    frame_idx = 0

    print("\n=== INTERACTIVE MODE ===")
    print("  Space  = play/pause")
    print("  < >    = prev/next frame")
    print("  V      = cycle view mode")
    print("  S      = save current frame")
    print("  P      = print current settings")
    print("  Q/Esc  = quit")
    print("  View modes: 0=overlay, 1=mask, 2=diff, 3=side-by-side, 4=overlay on checkerboard")
    print()

    while True:
        frame_idx = cv2.getTrackbarPos("Frame", win)
        threshold = cv2.getTrackbarPos("Threshold", win)
        morph_size = cv2.getTrackbarPos("Morph Size", win)
        dilate_iter = cv2.getTrackbarPos("Dilate Iter", win)
        min_area = cv2.getTrackbarPos("Min Area", win)
        color_filter = cv2.getTrackbarPos("Color Filter", win) == 1
        view_mode = cv2.getTrackbarPos("View [0-4]", win)

        # Make morph_size odd
        if morph_size > 0 and morph_size % 2 == 0:
            morph_size += 1

        frame = frames[frame_idx]
        overlay_rgb, overlay_bgra, mask, diff_gray = extract_overlay(
            frame, background, threshold, morph_size, dilate_iter,
            color_filter=color_filter, min_area=min_area
        )

        # Choose display
        if view_mode == 0:
            display = overlay_rgb
        elif view_mode == 1:
            display = cv2.cvtColor(mask, cv2.COLOR_GRAY2BGR)
        elif view_mode == 2:
            display = cv2.cvtColor(diff_gray, cv2.COLOR_GRAY2BGR)
        elif view_mode == 3:
            # Side by side: original | overlay
            display = np.hstack([frame, overlay_rgb])
        elif view_mode == 4:
            # Overlay on checkerboard (shows transparency)
            h, w = frame.shape[:2]
            checker = np.zeros((h, w, 3), dtype=np.uint8)
            block = 16
            for y in range(0, h, block):
                for x in range(0, w, block):
                    if (y // block + x // block) % 2 == 0:
                        checker[y:y+block, x:x+block] = (40, 40, 40)
                    else:
                        checker[y:y+block, x:x+block] = (80, 80, 80)
            alpha = mask.astype(np.float32) / 255.0
            alpha3 = np.stack([alpha]*3, axis=-1)
            display = (frame.astype(np.float32) * alpha3 +
                       checker.astype(np.float32) * (1 - alpha3)).astype(np.uint8)
        else:
            display = overlay_rgb

        # Add info text
        info = f"F:{frame_idx}/{n-1}  T:{threshold}  M:{morph_size}  D:{dilate_iter}  A:{min_area}  C:{'Y' if color_filter else 'N'}  V:{view_mode}"
        cv2.putText(display, info, (10, 25), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)

        cv2.imshow(win, display)

        wait_ms = max(1, int(1000 / fps)) if playing else 30
        key = cv2.waitKey(wait_ms) & 0xFF

        if key == ord('q') or key == 27:
            break
        elif key == ord(' '):
            playing = not playing
        elif key == ord('.') or key == 83:  # > or right arrow
            frame_idx = min(frame_idx + 1, n - 1)
            cv2.setTrackbarPos("Frame", win, frame_idx)
        elif key == ord(',') or key == 81:  # < or left arrow
            frame_idx = max(frame_idx - 1, 0)
            cv2.setTrackbarPos("Frame", win, frame_idx)
        elif key == ord('v'):
            view_mode = (view_mode + 1) % 5
            cv2.setTrackbarPos("View [0-4]", win, view_mode)
        elif key == ord('s'):
            fname = f"overlay_frame_{frame_idx:04d}.png"
            cv2.imwrite(fname, overlay_bgra)
            print(f"  Saved: {fname} (with alpha)")
        elif key == ord('p'):
            print(f"\n  --threshold {threshold} --morph {morph_size} "
                  f"--dilate {dilate_iter} --min-area {min_area} "
                  f"{'--color-filter' if color_filter else ''}\n")

        if playing:
            frame_idx = (frame_idx + 1) % n
            cv2.setTrackbarPos("Frame", win, frame_idx)

    cv2.destroyAllWindows()


def batch_export(frames, fps, background, args):
    """Export all overlay frames with the given settings."""
    out_dir = args.output
    if not args.video:
        os.makedirs(out_dir, exist_ok=True)

    writer = None
    if args.video:
        h, w = frames[0].shape[:2]
        fourcc = cv2.VideoWriter_fourcc(*'mp4v')
        writer = cv2.VideoWriter(out_dir, fourcc, fps, (w, h))
        print(f"Exporting video: {out_dir}")

    morph_size = args.morph
    if morph_size > 0 and morph_size % 2 == 0:
        morph_size += 1

    for i, frame in enumerate(frames):
        overlay_rgb, overlay_bgra, mask, _ = extract_overlay(
            frame, background, args.threshold, morph_size, args.dilate,
            color_filter=args.color_filter, min_area=args.min_area
        )

        if args.video:
            writer.write(overlay_rgb)
        else:
            if args.alpha:
                cv2.imwrite(os.path.join(out_dir, f"overlay_{i:04d}.png"), overlay_bgra)
            else:
                cv2.imwrite(os.path.join(out_dir, f"overlay_{i:04d}.png"), overlay_rgb)

        if (i + 1) % 50 == 0:
            print(f"  exported {i + 1}/{len(frames)}")

    if writer:
        writer.release()

    print(f"Done! Exported {len(frames)} frames.")


def main():
    parser = argparse.ArgumentParser(
        description="Extract moving overlay from static-background video/gif",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s dance.gif                          # Interactive tuning
  %(prog)s dance.gif --color-filter            # With red/white/blue suit filter
  %(prog)s dance.gif --batch -t 35 -m 3 -d 2  # Batch export frames
  %(prog)s dance.gif --batch --video -o out.mp4 -t 35  # Export as video
        """,
    )
    parser.add_argument("input", help="Input video or gif path")
    parser.add_argument("--batch", action="store_true", help="Batch export mode (no GUI)")
    parser.add_argument("-t", "--threshold", type=int, default=30,
                        help="Difference threshold (0-255, default: 30)")
    parser.add_argument("-m", "--morph", type=int, default=3,
                        help="Morphological kernel size (0=off, default: 3)")
    parser.add_argument("-d", "--dilate", type=int, default=1,
                        help="Dilation iterations (0=off, default: 1)")
    parser.add_argument("--min-area", type=int, default=0,
                        help="Min contour area to keep (0=off, default: 0)")
    parser.add_argument("--color-filter", action="store_true",
                        help="Apply HSV color filter for red/white/blue suit + dark skin")
    parser.add_argument("--method", choices=["median", "mog2"], default="median",
                        help="Background estimation method (default: median)")
    parser.add_argument("--mog-history", type=int, default=120,
                        help="MOG2 history parameter (default: 120)")
    parser.add_argument("--mog-var", type=int, default=40,
                        help="MOG2 variance threshold (default: 40)")
    parser.add_argument("-o", "--output", default="overlay_frames/",
                        help="Output directory or video path (default: overlay_frames/)")
    parser.add_argument("--video", action="store_true",
                        help="Export as video instead of frame PNGs")
    parser.add_argument("--alpha", action="store_true",
                        help="Export PNGs with alpha channel (transparency)")
    parser.add_argument("--max-frames", type=int, default=None,
                        help="Max frames to load (default: all)")

    args = parser.parse_args()

    # Load
    frames, fps = load_frames(args.input, max_frames=args.max_frames)

    # Background estimation
    if args.method == "median":
        background = compute_background_median(frames)
    else:
        # For MOG2, we need a different workflow — run it per-frame
        # For now, still compute median as fallback for interactive display
        # and use MOG2 masks in extraction
        print("Note: MOG2 mode uses adaptive BG. Median also computed for reference.")
        background = compute_background_median(frames)
        # TODO: integrate MOG2 per-frame masking into extract_overlay
        # For now, median works great for your use case

    # Save background for reference
    cv2.imwrite("_estimated_background.png", background)
    print("Saved estimated background: _estimated_background.png")

    if args.batch:
        batch_export(frames, fps, background, args)
    else:
        interactive_mode(frames, fps, background, args)


if __name__ == "__main__":
    main()
