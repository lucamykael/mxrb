package com.mendix.core.objectmanagement.member;

import com.mendix.systemwideinterfaces.core.IMendixObject;

/** A member of type Integer of an object. */
public class MendixInteger extends MendixObjectMember<Integer> {
	public MendixInteger(IMendixObject object, String name) {
		super(object, name);
	}
}
