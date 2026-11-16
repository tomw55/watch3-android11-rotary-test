package org.watch3.cibinder;

import android.app.Activity;
import android.app.Service;
import android.content.*;
import android.os.*;
import android.util.Log;
import java.util.UUID;

public final class Probe extends Activity {
    static final String TAG = "Watch3BinderCI";
    static final String DESCRIPTOR = "org.watch3.cibinder.echo";
    static final int ECHO = IBinder.FIRST_CALL_TRANSACTION;

    public static final class Remote extends Service {
        @Override public IBinder onBind(Intent intent) {
            return new Binder() {
                @Override protected boolean onTransact(int code, Parcel in, Parcel out, int flags)
                        throws RemoteException {
                    if (code != ECHO) return super.onTransact(code, in, out, flags);
                    in.enforceInterface(DESCRIPTOR);
                    String nonce = in.readString();
                    int caller = Binder.getCallingPid();
                    int uid = Binder.getCallingUid();
                    int server = android.os.Process.myPid();
                    Log.i(TAG, "SERVER " + nonce + " " + caller + " " + server + " " + uid);
                    out.writeNoException();
                    out.writeString(nonce);
                    out.writeInt(caller);
                    out.writeInt(server);
                    out.writeInt(uid);
                    return true;
                }
            };
        }
    }

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        final String nonce = getIntent().getStringExtra("nonce");
        if (nonce == null || !nonce.matches("[0-9a-f]{32}"))
            throw new IllegalArgumentException("Expected CI challenge");
        if (!bindService(new Intent(this, Remote.class), new ServiceConnection() {
            @Override public void onServiceDisconnected(ComponentName name) {}
            @Override public void onServiceConnected(ComponentName name, IBinder binder) {
                Parcel in = Parcel.obtain();
                Parcel out = Parcel.obtain();
                try {
                    if (binder instanceof Binder) throw new IllegalStateException("Local Binder");
                    in.writeInterfaceToken(DESCRIPTOR);
                    in.writeString(nonce);
                    if (!binder.transact(ECHO, in, out, 0))
                        throw new IllegalStateException("Transaction rejected");
                    out.readException();
                    String echoed = out.readString();
                    int caller = out.readInt(), server = out.readInt(), uid = out.readInt();
                    if (!nonce.equals(echoed) || caller != android.os.Process.myPid()
                            || server <= 0 || caller == server || uid != android.os.Process.myUid())
                        throw new IllegalStateException("Remote reply mismatch");
                    Log.i(TAG, "CLIENT " + nonce + " " + caller + " " + server + " " + uid);
                } catch (RemoteException | RuntimeException error) {
                    Log.e(TAG, "FAIL " + nonce, error);
                } finally {
                    in.recycle();
                    out.recycle();
                }
            }
        }, BIND_AUTO_CREATE)) throw new IllegalStateException("Bind rejected");
    }
}
