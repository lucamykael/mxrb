package mxrb.sidecar;

import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IMendixIdentifier;
import com.mendix.systemwideinterfaces.core.IMendixObject;
import com.mendix.systemwideinterfaces.core.ISession;
import com.mendix.systemwideinterfaces.core.IUser;

/** The calling microflow's context; its transaction stays in the Ruby application. */
public final class MxContext implements IContext {
	private final Bridge bridge;
	private final boolean sudo;

	public MxContext(Bridge bridge, boolean sudo) {
		this.bridge = bridge;
		this.sudo = sudo;
	}

	public Bridge bridge() {
		return bridge;
	}

	@Override
	public ISession getSession() {
		IContext context = this;
		return new ISession() {
			@Override
			public IUser getUser(IContext ignored) {
				IMendixObject user = getCurrentUserObject();
				return user == null ? null : new IUser() {
					@Override
					public String getName() {
						return user.getValue(context, "Name");
					}

					@Override
					public IMendixObject getMendixObject() {
						return user;
					}
				};
			}

			@Override
			public String getUserName() {
				IUser user = getUser(context);
				return user == null ? null : user.getName();
			}

			@Override
			public IMendixIdentifier getUserId() {
				IMendixObject user = getCurrentUserObject();
				return user == null ? null : user.getId();
			}

			@Override
			public boolean isSystemSession() {
				return getCurrentUserObject() == null;
			}

			@Override
			public IContext createContext() {
				return new MxContext(bridge, false);
			}
		};
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
		return new MxContext(bridge, sudo);
	}

	@Override
	public IContext createSudoClone() {
		return new MxContext(bridge, true);
	}

	@Override
	public void startTransaction() {
		throw new UnsupportedOperationException("the Ruby application owns the transaction");
	}

	@Override
	public void endTransaction() {
		bridge.call("end_transaction");
	}

	@Override
	public void rollbackTransaction() {
		throw new UnsupportedOperationException("the Ruby application owns the transaction");
	}

	@Override
	public IMendixObject getCurrentUserObject() {
		return (IMendixObject) bridge.call("user");
	}
}
