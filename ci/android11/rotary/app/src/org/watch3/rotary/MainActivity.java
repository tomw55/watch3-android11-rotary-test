package org.watch3.rotary;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.view.Gravity;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * Rotary fixture, with a documented and testable caveat.
 *
 * IMPORTANT terminology note (this is a correction from an earlier
 * revision): every log line below reports a motion event's SOURCE and
 * its ACTION separately, and they must never be read as one combined
 * promise. SOURCE says which class of input device produced the event
 * (SOURCE_ROTARY_ENCODER, SOURCE_MOUSE, SOURCE_TOUCHPAD, ...). ACTION
 * says what kind of event it is (ACTION_SCROLL, ACTION_HOVER_MOVE,
 * ACTION_HOVER_ENTER, ACTION_HOVER_EXIT, ...). The two vary
 * independently:
 *
 *   - REL_WHEEL (the bezel rotation itself) can generate an
 *     ACTION_SCROLL event carrying AXIS_SCROLL when delivered through a
 *     rotary-encoder mapper (SOURCE_ROTARY_ENCODER), OR an ACTION_SCROLL
 *     event carrying AXIS_VSCROLL/AXIS_HSCROLL when delivered through a
 *     cursor-class mapper (SOURCE_MOUSE or SOURCE_TOUCHPAD), depending on
 *     which mapper Android 11 actually attaches to this device.
 *   - REL_X only moves the on-screen pointer. By itself it produces
 *     ACTION_HOVER_MOVE/ACTION_HOVER_ENTER/ACTION_HOVER_EXIT events (plain
 *     cursor motion), NOT a scroll action and NOT an AXIS_VSCROLL/
 *     AXIS_HSCROLL value -- a hover event's scroll axis values are zero.
 *     This fixture does NOT promise, and must not be read as promising,
 *     that mouse hover or pointer movement will be logged as cursor
 *     scroll: hover and scroll are different actions, logged with
 *     different "action=" and "isScroll="/"isHover=" fields below, never
 *     merged into one.
 *
 * Why this matters here: the real tizen_bezel driver (and the matched
 * uinput generator, see ../../../rotary-uinput.c) advertises
 * EV_KEY/BTN_LEFT and EV_REL/REL_X,REL_Y capabilities alongside
 * EV_REL/REL_WHEEL. Android 11's InputReader classifies devices by their
 * full advertised capability set, and a BTN_MOUSE-like button plus
 * relative X/Y axes is the same heuristic InputReader uses to recognise
 * a cursor/trackball-class device. Loading "device.type = rotaryEncoder"
 * in the IDC is expected to ADD a rotary classification on top of this
 * -- it is not documented, and should not be assumed, to SUPPRESS the
 * cursor classification the other capabilities would otherwise trigger.
 * So a single physical rotation is expected to be able to produce BOTH:
 *   - a SOURCE_ROTARY_ENCODER / ACTION_SCROLL event carrying AXIS_SCROLL
 *     (the intended path, built from REL_WHEEL), delivered to whichever
 *     view currently has focus, and
 *   - a SOURCE_MOUSE or SOURCE_TOUCHPAD event built from the REL_X value
 *     the real driver and generator both emit in the SAME SYN_REPORT
 *     frame as REL_WHEEL, delivered by hit-testing (i.e. to whatever view
 *     the virtual pointer is currently over, which is NOT necessarily the
 *     focused view). Depending on how Android 11 maps this specific
 *     capability set, that second event could itself be ACTION_SCROLL
 *     carrying AXIS_VSCROLL/AXIS_HSCROLL, or it could be a plain
 *     ACTION_HOVER_MOVE with no scroll axis at all -- this fixture logs
 *     both possibilities distinctly rather than assuming either one.
 *
 * This is a real, concrete, currently-untested risk: if it happens, a
 * production build could see spurious cursor/scroll side effects, or
 * spurious pointer movement, on every bezel rotation. This fixture
 * cannot prove or disprove it without a booted guest (static review and
 * host-only tests cannot exercise InputReader's mapper selection), but it
 * is built so that once a guest exists, a single capture can show
 * whether this happens and to which view each class of event was
 * actually delivered:
 *
 *   - "fixture" is focusable and requests focus, so it is the expected
 *     target of the rotary-class event.
 *   - "decoy" is deliberately never focused and sits beside it, so if a
 *     cursor-class event is delivered by hit-testing instead of focus,
 *     and the virtual pointer happens to be positioned over it, its log
 *     line -- tagged distinctly -- shows that a second, different view
 *     received a motion event from the same physical rotation.
 *
 * A log line with view=decoy never appearing during a capture does NOT
 * by itself establish that no cursor-class mapper is attached: it only
 * shows that no event whose hit-test landed on the decoy's screen region
 * was observed in that capture. The pointer may simply not have been
 * positioned over the decoy, the cursor-class mapper's events may all
 * have hit-tested onto "fixture" or elsewhere instead, or a GenericMotion
 * listener may not be the delivery path a given cursor-class action
 * takes. The guest procedure below must independently inspect
 * `dumpsys input` for the device's attached mappers; decoy silence alone
 * is not sufficient evidence of their absence.
 *
 * Both views share the same listener logic; only the view tag differs
 * in the log line, so a capture can be grepped per view. Every log line
 * also carries the originating input device's numeric id (deviceId), its
 * source, its action, and both the rotary and the cursor-mapper scroll
 * axis values, so a capture can be correlated across all of
 * device id + source + action + scroll axes together -- axis values
 * alone are not a reliable correlation key, since a HOVER-class action
 * always reports zero for every scroll axis regardless of device.
 */
public final class MainActivity extends Activity {
    private static final String TAG = "Watch3Rotary";
    private TextView fixture;
    private TextView decoy;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);

        fixture = new TextView(this);
        fixture.setText("Rotary fixture. Inspect logcat Watch3Rotary.");
        fixture.setFocusableInTouchMode(true);
        fixture.setOnGenericMotionListener((view, event) -> recordMotion("fixture", view, event));

        decoy = new TextView(this);
        decoy.setText("Decoy (never focused). A cursor-class log line tagged "
                + "view=decoy means a hit-tested event from this device landed "
                + "here instead of on the focused fixture -- but its absence "
                + "does not prove no cursor-class mapper is attached; check "
                + "dumpsys input too.");
        decoy.setFocusable(false);
        decoy.setFocusableInTouchMode(false);
        decoy.setOnGenericMotionListener((view, event) -> recordMotion("decoy", view, event));

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER);
        root.addView(fixture);
        root.addView(decoy);
        setContentView(root);

        fixture.requestFocus();
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        Log.i(TAG, "windowFocus=" + focused + " viewFocus(fixture)=" + fixture.hasFocus()
                + " viewFocus(decoy)=" + decoy.hasFocus()
                + " rotation=" + getWindowManager().getDefaultDisplay().getRotation());
    }

    /**
     * Classifies and logs every GenericMotionEvent delivered to either
     * view -- this includes both ACTION_SCROLL events and plain pointer
     * ACTION_HOVER_ENTER/MOVE/EXIT events, since Android dispatches hover
     * through the same listener. SOURCE and ACTION are always reported
     * as separate fields and must be read that way; neither is inferred
     * from the other.
     *
     * "mapperClass" below names which MAPPER produced the event (by
     * source: ROTARY, CURSOR, or OTHER) -- it never names and must never
     * be read as naming which ACTION the event carries. A single mapper
     * can legitimately produce more than one kind of action: in
     * particular, the CURSOR-class mapper on this device is expected to
     * be able to deliver both plain ACTION_HOVER_MOVE events (from REL_X
     * alone, no scroll) and, depending on Android 11's mapping of this
     * capability set, ACTION_SCROLL events carrying AXIS_VSCROLL/
     * AXIS_HSCROLL (from REL_WHEEL riding on the same device). The
     * "isScroll"/"isHover" fields in the log line are what distinguish
     * those two cases -- "mapperClass=CURSOR" alone does not.
     *
     * Returns true (consumes the event) only for the rotary/ACTION_SCROLL
     * case, matching the real app's intended behaviour. Every other case
     * -- including a cursor-mapper hover or scroll event from the SAME
     * physical rotation -- is logged but NOT consumed, so default OS
     * handling (e.g. actual cursor movement) is left intact rather than
     * silently suppressed, and nothing here hides the composite-mapper
     * risk by swallowing it.
     */
    private boolean recordMotion(String viewTag, View view, MotionEvent event) {
        final int action = event.getActionMasked();
        final boolean fromRotary = event.isFromSource(InputDevice.SOURCE_ROTARY_ENCODER);
        final boolean fromMouse = event.isFromSource(InputDevice.SOURCE_MOUSE);
        final boolean fromTouchpad = event.isFromSource(InputDevice.SOURCE_TOUCHPAD);
        final boolean isScroll = action == MotionEvent.ACTION_SCROLL;
        final boolean isHover = action == MotionEvent.ACTION_HOVER_MOVE
                || action == MotionEvent.ACTION_HOVER_ENTER
                || action == MotionEvent.ACTION_HOVER_EXIT;

        final String mapperClass = fromRotary ? "ROTARY"
                : (fromMouse || fromTouchpad) ? "CURSOR"
                : "OTHER";
        final boolean rotaryScroll = fromRotary && isScroll;

        final InputDevice device = event.getDevice();
        Log.i(TAG, "view=" + viewTag
                + " mapperClass=" + mapperClass
                + " action=" + MotionEvent.actionToString(action)
                + " isScroll=" + isScroll
                + " isHover=" + isHover
                + " viewFocus=" + view.hasFocus() + " windowFocus=" + view.hasWindowFocus()
                + " deviceId=" + event.getDeviceId()
                + " device=" + (device == null ? "unknown" : device.getName())
                + " eventTime=" + event.getEventTime()
                + " source=0x" + Integer.toHexString(event.getSource())
                + " AXIS_SCROLL=" + event.getAxisValue(MotionEvent.AXIS_SCROLL)
                + " AXIS_VSCROLL=" + event.getAxisValue(MotionEvent.AXIS_VSCROLL)
                + " AXIS_HSCROLL=" + event.getAxisValue(MotionEvent.AXIS_HSCROLL)
                + " rotation=" + getWindowManager().getDefaultDisplay().getRotation());

        return rotaryScroll;
    }
}
