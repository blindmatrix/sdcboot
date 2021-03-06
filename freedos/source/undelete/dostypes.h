/*
  FreeDOS special UNDELETE tool (and mirror, kind of)
  Copyright (C) 2001, 2002  Eric Auer <eric@CoLi.Uni-SB.DE>

  This program is free software; you can redistribute it and/or
  modify it under the terms of the GNU General Public License
  as published by the Free Software Foundation; either version 2
  of the License, or (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, 
  USA. Or check http://www.gnu.org/licenses/gpl.txt on the internet.
*/


#ifndef DOSTYPES_H
#define DOSTYPES_H

/* those seem to work for both Unix gcc and DOS Turbo C */

/*
 *  #define Byte unsigned char
 *  #define Word unsigned short int  ---  has to be 16 bit...
 *  #define Dword unsigned long int  ---  has to be 32 bit...
 */

/* A more clean way to do the above. -- Emanuele Cipolla. */

typedef unsigned char Byte;
typedef unsigned short int Word;
typedef unsigned long int Dword;

#endif
