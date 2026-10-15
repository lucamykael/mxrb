package mxrb.sidecar;

import java.util.ArrayList;
import java.util.List;

import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IMendixIdentifier;
import com.mendix.systemwideinterfaces.core.IMendixObject;

/** An object of the Ruby application, by its handle in the invocation. */
public final class MxObject implements IMendixObject {
	private final Bridge bridge;
	private final long handle;
	private final String entity;
	private final String id;

	MxObject(Bridge bridge, long handle, String entity, String id) {
		this.bridge = bridge;
		this.handle = handle;
		this.entity = entity;
		this.id = id;
	}

	long handle() {
		return handle;
	}

	String guid() {
		return id;
	}

	@Override
	public String getType() {
		return entity;
	}

	@Override
	public void setValue(IContext context, String member, Object value) {
		bridge.call("set", "object", this, "member", member, "value", value);
	}

	/** An association is read as the identifiers of the objects it refers to. */
	@Override
	@SuppressWarnings("unchecked")
	public <T> T getValue(IContext context, String member) {
		Object value = bridge.call("get", "object", this, "member", member);
		if (value instanceof MxObject object) {
			return (T) object.getId();
		}
		if (value instanceof List<?> list) {
			List<Object> ids = new ArrayList<>();
			for (Object item : list) {
				ids.add(item instanceof MxObject object ? object.getId() : item);
			}
			return (T) ids;
		}
		return (T) value;
	}

	@Override
	public boolean hasMember(String member) {
		return bridge.call("member", "object", this, "member", member) != null;
	}

	@Override
	public IMendixIdentifier getId() {
		return new MxIdentifier(this);
	}

	@Override
	public boolean isChanged() {
		return Boolean.TRUE.equals(bridge.call("changed", "object", this));
	}

	@Override
	public boolean equals(Object other) {
		return other instanceof MxObject object && object.entity.equals(entity) && object.id.equals(id);
	}

	@Override
	public int hashCode() {
		return id.hashCode();
	}

	@Override
	public String toString() {
		return entity + " " + id;
	}
}
