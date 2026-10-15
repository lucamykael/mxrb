package mxrb.sidecar;

import java.util.UUID;

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

	/** A stable number for the object's UUID; the Ruby application has no numeric ids. */
	@Override
	public long toLong() {
		try {
			return UUID.fromString(object.guid()).getMostSignificantBits() & Long.MAX_VALUE;
		} catch (IllegalArgumentException e) {
			return object.guid().hashCode() & Long.MAX_VALUE;
		}
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
