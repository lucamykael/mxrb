package mxrb.sidecar;

import java.util.Map;
import java.util.UUID;

import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IMendixIdentifier;
import com.mendix.systemwideinterfaces.core.IMendixObject;
import com.mendix.systemwideinterfaces.core.ISession;
import com.mendix.systemwideinterfaces.core.IUser;

/** A session of the Ruby application: its id, its user, and whether it is a guest's. */
public final class MxSession implements ISession {
	private final Bridge bridge;
	private final String id;
	private final MxObject user;
	private final String name;
	private final boolean anonymous;

	MxSession(Bridge bridge, Map<String, Object> session) {
		this.bridge = bridge;
		this.id = (String) session.get("id");
		this.user = (MxObject) session.get("user");
		this.name = (String) session.get("name");
		this.anonymous = Boolean.TRUE.equals(session.get("anonymous"));
	}

	/** A session the Ruby application describes as its id, user, name and whether it is a guest's. */
	public static MxSession of(Bridge bridge, Map<String, Object> session) {
		return new MxSession(bridge, session);
	}

	/** The session of the context Ruby calls with; a system session when there is none. */
	@SuppressWarnings("unchecked")
	static MxSession current(Bridge bridge) {
		return new MxSession(bridge, (Map<String, Object>) bridge.call("session"));
	}

	@Override
	public UUID getId() {
		return id == null ? null : UUID.fromString(id);
	}

	@Override
	public IUser getUser(IContext context) {
		if (user == null && !anonymous) {
			return null;
		}
		return new IUser() {
			@Override
			public String getName() {
				return name;
			}

			@Override
			public IMendixObject getMendixObject() {
				return user;
			}

			@Override
			public Boolean isAnonymous() {
				return anonymous;
			}
		};
	}

	@Override
	public String getUserName() {
		return name;
	}

	@Override
	public IMendixIdentifier getUserId() {
		return user == null ? null : user.getId();
	}

	@Override
	public boolean isSystemSession() {
		return user == null && !anonymous;
	}

	@Override
	public IContext createContext() {
		return new MxContext(bridge, false, this);
	}

	@Override
	public String toString() {
		return "session " + id;
	}
}
