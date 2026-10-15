package mxrb.sidecar;

import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IMendixObject;
import com.mendix.systemwideinterfaces.core.ISession;

/** The calling microflow's context; its transaction stays in the Ruby application. */
public final class MxContext implements IContext {
	private final Bridge bridge;
	private final boolean sudo;
	private MxSession session;
	private int transactions;

	public MxContext(Bridge bridge, boolean sudo) {
		this(bridge, sudo, null);
	}

	MxContext(Bridge bridge, boolean sudo, MxSession session) {
		this.bridge = bridge;
		this.sudo = sudo;
		this.session = session;
	}

	public Bridge bridge() {
		return bridge;
	}

	@Override
	public ISession getSession() {
		if (session == null) {
			session = MxSession.current(bridge);
		}
		return session;
	}

	@Override
	public boolean isSudo() {
		return sudo;
	}

	@Override
	public boolean isInTransaction() {
		return true;
	}

	@Override
	public IContext createClone() {
		return new MxContext(bridge, sudo, session);
	}

	@Override
	public IContext createSudoClone() {
		return new MxContext(bridge, true, session);
	}

	/** A transaction the action starts nests in the Ruby application's, which keeps the work. */
	@Override
	public void startTransaction() {
		transactions++;
	}

	/** Ends a transaction this context started, or else the calling microflow's. */
	@Override
	public void endTransaction() {
		if (transactions > 0) {
			transactions--;
		} else {
			bridge.call("end_transaction");
		}
	}

	@Override
	public void rollbackTransaction() {
		if (transactions == 0) {
			throw new UnsupportedOperationException("the Ruby application owns the transaction");
		}
		transactions--;
	}

	/** The user a microflow called with this context runs as, or null for the caller's. */
	String userName() {
		return session == null || session.getUserId() == null ? null : session.getUserName();
	}

	@Override
	public IMendixObject getCurrentUserObject() {
		return getSession().getUser(this) == null ? null : getSession().getUser(this).getMendixObject();
	}
}
