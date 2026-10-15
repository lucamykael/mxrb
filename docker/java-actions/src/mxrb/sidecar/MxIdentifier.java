package mxrb.sidecar;

import com.mendix.systemwideinterfaces.core.IMendixIdentifier;
import com.mendix.systemwideinterfaces.core.IMendixObject;

/** The identity of an object of the Ruby application. */
public final class MxIdentifier implements IMendixIdentifier {
	private final MxObject object;

	MxIdentifier(MxObject object) {
		this.object = object;
	}

	@Override
	public String getObjectType() {
		return object.getType();
	}

	/**
	 * The number the Ruby application keeps for the object, which
	 * Core.createMendixIdentifier turns back into it, as a stored id would.
	 */
	@Override
	public long toLong() {
		return (Long) object.bridge().call("long_id", "object", object);
	}

	@Override
	public IMendixObject getObject() {
		return object;
	}

	@Override
	public boolean equals(Object other) {
		return other instanceof MxIdentifier id && id.object.equals(object);
	}

	@Override
	public int hashCode() {
		return object.hashCode();
	}

	@Override
	public String toString() {
		return "ID_" + object.guid();
	}
}
