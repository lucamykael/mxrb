package com.mendix.systemwideinterfaces.core.meta;

/** An association from a parent entity, which owns it, to a child entity. */
public interface IMetaAssociation extends IMetaObjectMember {
	/** A reference to one object or to a set of them. */
	enum AssociationType { REFERENCE, REFERENCESET }

	/** Which side stores the association. */
	enum AssociationOwner { DEFAULT, BOTH }

	IMetaObject getChild();
	AssociationOwner getOwner();
	IMetaObject getParent();
	AssociationType getType();
}
