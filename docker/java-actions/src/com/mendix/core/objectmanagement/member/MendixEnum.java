package com.mendix.core.objectmanagement.member;

import com.mendix.systemwideinterfaces.core.IMendixObject;
import com.mendix.systemwideinterfaces.core.meta.IMetaEnumeration;

/** An enumeration attribute of an object; its value is the value's identifier. */
public class MendixEnum extends MendixObjectMember<String> {
	private final IMetaEnumeration enumeration;

	public MendixEnum(IMendixObject object, String name, IMetaEnumeration enumeration) {
		super(object, name);
		this.enumeration = enumeration;
	}

	public IMetaEnumeration getEnumeration() {
		return enumeration;
	}
}
