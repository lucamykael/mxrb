package com.mendix.systemwideinterfaces.core.meta;

import java.util.Collection;
import java.util.List;

/** An entity of the application or of the System module. */
public interface IMetaObject {
	String getModuleName();
	String getName();
	String getSuperName();
	IMetaObject getSuperObject();
	List<? extends IMetaObject> getSuperObjects();
	List<? extends IMetaObject> getSubObjects();
	boolean isSubClassOf(String name);
	Boolean isPersistable();
	boolean hasCreatedDateAttr();
	boolean hasChangedDateAttr();
	boolean hasOwnerAttr();
	boolean hasChangedByAttr();
	Collection<? extends IMetaPrimitive> getMetaPrimitives();
	IMetaPrimitive getMetaPrimitive(String name);
	Collection<? extends IMetaPrimitive> getDeclaredMetaPrimitives();
	Collection<? extends IMetaPrimitive> getNonVirtualDeclaredMetaPrimitives();
	IMetaPrimitive getDeclaredMetaPrimitive(String name);
	Collection<? extends IMetaAssociation> getMetaAssociationsChild();
	IMetaAssociation getMetaAssociationChild(String name);
	Collection<? extends IMetaAssociation> getMetaAssociationsParent();
	IMetaAssociation getMetaAssociationParent(String name);
	Collection<? extends IMetaAssociation> getDeclaredMetaAssociationsChild();
	IMetaAssociation getDeclaredMetaAssociationChild(String name);
	Collection<? extends IMetaAssociation> getDeclaredMetaAssociationsParent();
	IMetaAssociation getDeclaredMetaAssociationParent(String name);
	boolean isUser();
	boolean isFileDocument();

	default boolean isSubClassOf(IMetaObject other) {
		return isSubClassOf(other.getName());
	}
}
