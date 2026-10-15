package com.mendix.systemwideinterfaces.core;

import java.util.List;
import java.util.Map;

import com.mendix.core.objectmanagement.member.MendixObjectReference;
import com.mendix.core.objectmanagement.member.MendixObjectReferenceSet;
import com.mendix.systemwideinterfaces.core.meta.IMetaObject;

/** An object of an entity, read and changed in the Ruby application's transaction. */
public interface IMendixObject {
	/** Whether the object was ever committed. */
	enum ObjectState { INSTANTIATED, AUTOCOMMITTED, NORMAL }

	String getType();
	void setValue(IContext context, String member, Object value);
	<T> T getValue(IContext context, String member);
	boolean hasMember(String member);
	IMendixObjectMember<?> getMember(String member);
	IMendixObjectMember<?> getMember(IContext context, String member);
	Map<String, ? extends IMendixObjectMember<?>> getMembers(IContext context);
	List<? extends IMendixObjectMember<?>> getPrimitives(IContext context);
	List<? extends MendixObjectReference> getReferences(IContext context);
	List<? extends MendixObjectReferenceSet> getReferenceSets(IContext context);
	List<? extends IMendixObjectMember<?>> getChangedMembers(IContext context);
	IMendixIdentifier getId();
	ObjectState getState();
	boolean isNew();
	boolean isChanged();
	IMetaObject getMetaObject();
	boolean hasOwnerAttribute();
	boolean hasChangedByAttribute();
	boolean hasCreatedDateAttribute();
	boolean hasChangedDateAttribute();
	boolean equals(Object other);
	int hashCode();

	default IMendixIdentifier getOwner(IContext context) {
		return getValue(context, "System.owner");
	}

	default IMendixIdentifier getChangedBy(IContext context) {
		return getValue(context, "System.changedBy");
	}

	default java.util.Date getCreatedDate(IContext context) {
		return getValue(context, "createdDate");
	}

	default java.util.Date getChangedDate(IContext context) {
		return getValue(context, "changedDate");
	}

	default boolean hasChangedMemberValue(IContext context) {
		return !getChangedMembers(context).isEmpty();
	}

	default boolean isInstanceOf(String entity) {
		return getMetaObject() == null ? getType().equals(entity) : getMetaObject().isSubClassOf(entity);
	}

	default boolean isInstanceOf(IMetaObject entity) {
		return isInstanceOf(entity.getName());
	}
}
