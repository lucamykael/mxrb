package com.mendix.core.objectmanagement.member;

import com.mendix.systemwideinterfaces.core.IMendixObject;

/** A member of type Long of an object. */
public class MendixAutoNumber extends MendixObjectMember<Long> {
	public MendixAutoNumber(IMendixObject object, String name) {
		super(object, name);
	}
}
