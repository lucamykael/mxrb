package com.mendix.core.objectmanagement.member;

import java.math.BigDecimal;
import java.util.Objects;

import com.mendix.systemwideinterfaces.core.IContext;
import com.mendix.systemwideinterfaces.core.IMendixObject;
import com.mendix.systemwideinterfaces.core.IMendixObjectMember;

import mxrb.sidecar.MxObject;

/** A member of an object, read and changed through the object. */
public abstract class MendixObjectMember<T> implements IMendixObjectMember<T> {
	private final IMendixObject object;
	private final String name;

	protected MendixObjectMember(IMendixObject object, String name) {
		this.object = object;
		this.name = name;
	}

	@Override
	public T getValue(IContext context) {
		return object.getValue(context, name);
	}

	@Override
	public void setValue(IContext context, T value) {
		object.setValue(context, name, value);
	}

	@Override
	public String parseValueToString(IContext context) {
		Object value = getValue(context);
		if (value == null) {
			return "";
		}
		return value instanceof BigDecimal decimal ? decimal.toPlainString() : String.valueOf(value);
	}

	@Override
	public boolean isVirtual() {
		return false;
	}

	@Override
	@SuppressWarnings("unchecked")
	public T getOriginalValue(IContext context) {
		return (T) ((MxObject) object).original(name);
	}

	@Override
	public MemberState getState() {
		return isChanged() ? MemberState.CHANGED : MemberState.UNCHANGED;
	}

	@Override
	public String getName() {
		return name;
	}

	/** Whether the value differs from the one at the last commit; a new object's members all changed. */
	@Override
	public boolean isChanged() {
		MxObject owner = (MxObject) object;
		return owner.isNew() || !Objects.equals(owner.getValue(null, name), owner.original(name));
	}

	@Override
	public String toString() {
		return name;
	}
}
