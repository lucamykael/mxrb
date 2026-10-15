package mxrb.sidecar;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.mendix.core.objectmanagement.member.MendixAutoNumber;
import com.mendix.core.objectmanagement.member.MendixBinary;
import com.mendix.core.objectmanagement.member.MendixBoolean;
import com.mendix.core.objectmanagement.member.MendixDateTime;
import com.mendix.core.objectmanagement.member.MendixDecimal;
import com.mendix.core.objectmanagement.member.MendixEnum;
import com.mendix.core.objectmanagement.member.MendixHashString;
import com.mendix.core.objectmanagement.member.MendixInteger;
import com.mendix.core.objectmanagement.member.MendixLong;
import com.mendix.core.objectmanagement.member.MendixObjectMember;
import com.mendix.core.objectmanagement.member.MendixObjectReference;
import com.mendix.core.objectmanagement.member.MendixObjectReferenceSet;
import com.mendix.core.objectmanagement.member.MendixString;
import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IMendixIdentifier;
import com.mendix.systemwideinterfaces.core.IMendixObject;
import com.mendix.systemwideinterfaces.core.IMendixObjectMember;
import com.mendix.systemwideinterfaces.core.meta.IMetaAssociation;

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

	Bridge bridge() {
		return bridge;
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
		return (T) identifiers(bridge.call("get", "object", this, "member", member));
	}

	/** A member's value at the last commit; null for an object never committed. */
	@SuppressWarnings("unchecked")
	public Object original(String member) {
		Map<String, Object> members = (Map<String, Object>) bridge.call("original", "object", this);
		if (members == null) {
			return null;
		}
		int dot = member.lastIndexOf('.');
		return identifiers(members.get(dot < 0 ? member : member.substring(dot + 1)));
	}

	@Override
	public boolean isNew() {
		return bridge.call("original", "object", this) == null;
	}

	@Override
	public ObjectState getState() {
		return isNew() ? ObjectState.INSTANTIATED : ObjectState.NORMAL;
	}

	@Override
	public MxMetaObject getMetaObject() {
		return Metadata.get().object(entity);
	}

	/** The attributes, then the associations the entity owns, by name. */
	@Override
	public Map<String, MendixObjectMember<?>> getMembers(IContext context) {
		Map<String, MendixObjectMember<?>> members = new LinkedHashMap<>();
		MxMetaObject meta = getMetaObject();
		if (meta == null) {
			return members;
		}
		for (MxMetaPrimitive primitive : meta.getMetaPrimitives()) {
			members.put(primitive.getName(), primitive(primitive));
		}
		for (IMetaAssociation association : meta.getMetaAssociationsParent()) {
			members.put(association.getName(), association.getType() == IMetaAssociation.AssociationType.REFERENCESET
					? new MendixObjectReferenceSet(this, association.getName())
					: new MendixObjectReference(this, association.getName()));
		}
		return members;
	}

	@Override
	public IMendixObjectMember<?> getMember(String member) {
		return getMember(null, member);
	}

	@Override
	public IMendixObjectMember<?> getMember(IContext context, String member) {
		return getMembers(context).get(member);
	}

	@Override
	public List<MendixObjectMember<?>> getPrimitives(IContext context) {
		List<MendixObjectMember<?>> primitives = new ArrayList<>();
		for (MendixObjectMember<?> member : getMembers(context).values()) {
			if (!(member instanceof MendixObjectReference) && !(member instanceof MendixObjectReferenceSet)) {
				primitives.add(member);
			}
		}
		return primitives;
	}

	@Override
	public List<MendixObjectReference> getReferences(IContext context) {
		List<MendixObjectReference> references = new ArrayList<>();
		for (MendixObjectMember<?> member : getMembers(context).values()) {
			if (member instanceof MendixObjectReference reference) {
				references.add(reference);
			}
		}
		return references;
	}

	@Override
	public List<MendixObjectReferenceSet> getReferenceSets(IContext context) {
		List<MendixObjectReferenceSet> sets = new ArrayList<>();
		for (MendixObjectMember<?> member : getMembers(context).values()) {
			if (member instanceof MendixObjectReferenceSet set) {
				sets.add(set);
			}
		}
		return sets;
	}

	@Override
	public List<MendixObjectMember<?>> getChangedMembers(IContext context) {
		List<MendixObjectMember<?>> changed = new ArrayList<>();
		for (MendixObjectMember<?> member : getMembers(context).values()) {
			if (member.isChanged()) {
				changed.add(member);
			}
		}
		return changed;
	}

	@Override
	public boolean hasOwnerAttribute() {
		return getMetaObject() != null && getMetaObject().hasOwnerAttr();
	}

	@Override
	public boolean hasChangedByAttribute() {
		return getMetaObject() != null && getMetaObject().hasChangedByAttr();
	}

	@Override
	public boolean hasCreatedDateAttribute() {
		return getMetaObject() != null && getMetaObject().hasCreatedDateAttr();
	}

	@Override
	public boolean hasChangedDateAttribute() {
		return getMetaObject() != null && getMetaObject().hasChangedDateAttr();
	}

	private MendixObjectMember<?> primitive(MxMetaPrimitive primitive) {
		String name = primitive.getName();
		switch (primitive.getType()) {
		case AutoNumber:
			return new MendixAutoNumber(this, name);
		case Binary:
			return new MendixBinary(this, name);
		case Boolean:
			return new MendixBoolean(this, name);
		case DateTime:
			return new MendixDateTime(this, name);
		case Decimal:
			return new MendixDecimal(this, name);
		case Enum:
			return new MendixEnum(this, name, primitive.getEnumeration());
		case HashString:
			return new MendixHashString(this, name);
		case Integer:
			return new MendixInteger(this, name);
		case Long:
			return new MendixLong(this, name);
		default:
			return new MendixString(this, name);
		}
	}

	private static Object identifiers(Object value) {
		if (value instanceof MxObject object) {
			return object.getId();
		}
		if (value instanceof List<?> list) {
			List<Object> ids = new ArrayList<>();
			for (Object item : list) {
				ids.add(item instanceof MxObject object ? object.getId() : item);
			}
			return ids;
		}
		return value;
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
