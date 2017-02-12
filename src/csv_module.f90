!*****************************************************************************************
!> author: Jacob Williams
!  license: BSD
!
!  For reading and writing CSV files.

    module csv_module

    use utilities_module
    use kinds_module
    use iso_fortran_env

    implicit none

    private

    ! the different types of variables that can be in a CSV file.
    integer,parameter,public :: csv_type_string  = 1  !! a character string cell
    integer,parameter,public :: csv_type_double  = 2  !! a `real(wp)` cell
    integer,parameter,public :: csv_type_integer = 3  !! an `integer(ip)` cell
    integer,parameter,public :: csv_type_logical = 4  !! a logical cell

    real(wp),parameter :: zero = 0.0_wp

    type,public :: csv_string
        !! a cell from a CSV file.
        private
        character(len=:),allocatable :: str
    end type csv_string

    type,public :: csv_file

        !! the main class for reading and writing CSV files.
        !!
        !!@note A CSV file is assumed to contain the same number
        !!      of columns in each row. It may optionally contain
        !!      a header row.

        private

        logical :: verbose = .true. !! to print error messages

        character(len=1) :: quote     = '"'  !! quotation character
        character(len=1) :: delimiter = ','  !! delimiter character
        integer :: n_rows = 0  !! number of rows in the file
        integer :: n_cols = 0  !! number of columns in the file
        integer :: chunk_size = 100 !! for expanding vectors

        type(csv_string),dimension(:),allocatable :: header      !! the header
        type(csv_string),dimension(:,:),allocatable :: csv_data  !! the data in the file

        !for writing a csv file:
        integer :: icol = 0    !! last column written in current row
        integer :: iunit = 0  !! file unit for writing
        logical :: enclose_strings_in_quotes = .true.  !! if true, all string cells
                                                       !! will be enclosed in quotes.
        logical :: enclose_all_in_quotes = .false. !! if true, *all* cells will
                                                   !! be enclosed in quotes.

    contains

        private

        procedure,public :: initialize => initialize_csv_file
        procedure,public :: read => read_csv_file
        procedure,public :: destroy => destroy_csv_file

        procedure,public :: variable_types

        generic,public :: get_header => get_header_str,&
                                        get_header_csv_str
        procedure :: get_header_str
        procedure :: get_header_csv_str

        !>
        ! For getting data from the class
        ! after the file has been read.
        generic,public :: get => get_csv_data_as_str,&
                                 csv_get_value,&
                                 get_real_column,&
                                 get_integer_column,&
                                 get_logical_column,&
                                 get_character_column,&
                                 get_csv_string_column
        procedure :: get_csv_data_as_str
        procedure :: csv_get_value
        procedure :: get_real_column
        procedure :: get_integer_column
        procedure :: get_logical_column
        procedure :: get_character_column
        procedure :: get_csv_string_column

        procedure,public :: open => open_csv_file

        generic,public :: add => add_cell,&
                                 add_vector,&
                                 add_matrix
        procedure :: add_cell
        procedure :: add_vector
        procedure :: add_matrix

        procedure,public :: next_row
        procedure,public :: close => close_csv_file

        procedure :: tokenize => tokenize_csv_line
        procedure :: read_line_from_file
        procedure :: get_column

    end type csv_file

    contains
!*****************************************************************************************

!*****************************************************************************************
!>
!  Constructor.

    subroutine initialize_csv_file(me,quote,delimiter,&
                                    enclose_strings_in_quotes,&
                                    enclose_all_in_quotes,&
                                    verbose)

    implicit none

    class(csv_file),intent(out) :: me
    character(len=1),intent(in),optional :: quote             !! note: can only be one character
    character(len=1),intent(in),optional :: delimiter         !! note: can only be one character
    logical,intent(in),optional :: enclose_strings_in_quotes  !! if true, all string cells
                                                              !! will be enclosed in quotes.
    logical,intent(in),optional :: enclose_all_in_quotes      !! if true, *all* cells will
                                                              !! be enclosed in quotes.
    logical,intent(in),optional :: verbose

    if (present(quote)) me%quote = quote
    if (present(delimiter)) me%delimiter = delimiter
    if (present(enclose_strings_in_quotes)) &
        me%enclose_strings_in_quotes = enclose_strings_in_quotes
    if (present(enclose_all_in_quotes)) &
        me%enclose_all_in_quotes = enclose_all_in_quotes
    if (present(verbose)) me%verbose = verbose

    end subroutine initialize_csv_file
!*****************************************************************************************

!*****************************************************************************************
!>
!  Destroy the data in a CSV file.

    pure subroutine destroy_csv_file(me)

    implicit none

    class(csv_file),intent(inout) :: me

    if (allocated(me%csv_data)) deallocate(me%csv_data)
    if (allocated(me%header)) deallocate(me%header)

    me%n_cols = 0
    me%n_rows = 0
    me%icol   = 0

    end subroutine destroy_csv_file
!*****************************************************************************************

!*****************************************************************************************
!>
!  Read a CSV file.

    subroutine read_csv_file(me,filename,header_row,skip_rows,status_ok)

    implicit none

    class(csv_file),intent(inout) :: me
    character(len=*),intent(in) :: filename  !! the CSV file to open
    logical,intent(out) :: status_ok  !! status flag
    integer,intent(in),optional :: header_row  !! the header row
    integer,dimension(:),intent(in),optional :: skip_rows  !! rows to skip

    integer :: i                !! counter
    integer :: j                !! counter
    integer :: irow             !! row counter
    integer :: n_rows_in_file   !! number of lines in the file
    integer :: n_rows           !! number of rows in the output data matrix
    integer :: n_cols           !! number of columns in the file (and output data matrix)
    integer :: istat            !! open status flag
    integer :: iunit            !! open file unit
    integer,dimension(:),allocatable :: rows_to_skip  !! the actual rows to skip
    logical :: arrays_allocated  !! if the arrays in the class have been allocated
    type(csv_string),dimension(:),allocatable :: row_data  !! a tokenized row
    character(len=:),allocatable :: line  !! a line from the file
    integer :: iheader  !! row number of header row (0 if no header specified)

    call me%destroy()
    arrays_allocated = .false.

    open(newunit=iunit, file=filename, status='OLD', iostat=istat)

    if (istat==0) then

        !get number of lines in the file
        n_rows_in_file = number_of_lines_in_file(iunit)

        !get number of lines in the data array
        if (present(skip_rows)) then
            !get size of unique elements in skip_rows,
            !and subtract from n_rows_in_file
            rows_to_skip = unique(skip_rows,chunk_size=me%chunk_size)
            n_rows = n_rows_in_file - size(rows_to_skip)
        else
            n_rows = n_rows_in_file
        end if
        if (present(header_row)) then
            iheader = max(0,header_row)
            n_rows = n_rows - 1
        else
            iheader = 0
        end if

        me%n_rows = n_rows

        ! we don't know the number of columns
        ! until we parse the first row (or the header)

        !read each line in the file, parse it, and populate data
        irow = 0
        do i=1,n_rows_in_file  !! rows in the file

            ! skip row if necessary
            if (allocated(rows_to_skip)) then
                if (any(i==rows_to_skip)) cycle
            end if

            call me%read_line_from_file(iunit,line)
            call me%tokenize(line,row_data)

            if (.not. arrays_allocated) then
                ! note: the number of columns is obtained
                ! from the first one read. It is assumed
                ! that each row has the same number of
                ! columns.
                n_cols = size(row_data)
                me%n_cols = n_cols
                allocate(me%csv_data(n_rows,n_cols))
                if (iheader/=0) allocate(me%header(n_cols))
                arrays_allocated = .true.
            end if

            if (i==iheader) then
                do j=1,me%n_cols
                    me%header(j)%str = row_data(j)%str
                end do
            else
                irow = irow + 1  !! row counter in data array
                do j=1,n_cols
                    me%csv_data(irow,j) = row_data(j) !%str
                end do
            end if

        end do

        ! close the file
        close(unit=iunit,iostat=istat)

        status_ok = .true.

    else
        if (me%verbose) write(error_unit,'(A)') 'Error opening file: '//trim(filename)
        status_ok = .false.
    end if

    end subroutine read_csv_file
!*****************************************************************************************

!*****************************************************************************************
!>
!  Open a CSV file for writing

    subroutine open_csv_file(me,filename,&
                                n_cols,&
                                enclose_strings_in_quotes,&
                                enclose_all_in_quotes,&
                                status_ok)

    implicit none

    class(csv_file),intent(inout) :: me
    character(len=*),intent(in) :: filename  !! the CSV file to open
    integer,intent(in) :: n_cols  !! number of columns in the file
    logical,intent(in),optional :: enclose_strings_in_quotes  !! default is true
    logical,intent(in),optional :: enclose_all_in_quotes !! default is false
    logical,intent(out) :: status_ok  !! status flag

    integer :: istat  !! open `iostat` flag

    call me%destroy()

    me%n_cols = n_cols

    if (present(enclose_strings_in_quotes)) then
        me%enclose_strings_in_quotes = enclose_strings_in_quotes
    else
        me%enclose_strings_in_quotes = .true.
    end if
    if (present(enclose_all_in_quotes)) then
        me%enclose_all_in_quotes = enclose_all_in_quotes
    else
        me%enclose_all_in_quotes = .false.
    end if
    if (me%enclose_all_in_quotes) me%enclose_strings_in_quotes = .true. ! override

    open(newunit=me%iunit,file=filename,status='REPLACE',iostat=istat)
    if (istat==0) then
        status_ok = .true.
    else
        if (me%verbose) write(error_unit,'(A)') 'Error opening file: '//trim(filename)
        status_ok = .false.
    end if

    end subroutine open_csv_file
!*****************************************************************************************

!*****************************************************************************************
!>
!  Close a CSV file after writing

    subroutine close_csv_file(me,status_ok)

    implicit none

    class(csv_file),intent(inout) :: me
    logical,intent(out) :: status_ok  !! status flag

    integer :: istat  !! close `iostat` flag

    close(me%iunit,iostat=istat)
    status_ok = istat==0

    end subroutine close_csv_file
!*****************************************************************************************

!*****************************************************************************************
!>
!  Add a cell to a CSV file.

    subroutine add_cell(me,val,int_fmt,real_fmt,trim_str)

    implicit none

    class(csv_file),intent(inout) :: me
    class(*),intent(in) :: val  !! the value to add
    character(len=*),intent(in),optional :: int_fmt !! format string for integers
    character(len=*),intent(in),optional :: real_fmt !! format string for reals
    logical,intent(in),optional :: trim_str !! to trim the string

    integer :: istat !! write `iostat` flag
    character(len=:),allocatable :: ifmt !! actual format string to use for integers
    character(len=:),allocatable :: rfmt !! actual format string to use for REALS
    logical :: trimstr !! if the strings are to be trimmed
    character(len=max_real_str_len) :: real_val
    character(len=max_integer_str_len) :: int_val

    !TODO need to check the istat values for errors

    ! make sure the row isn't already finished
    if (me%icol<me%n_cols) then

        me%icol = me%icol + 1

        if (me%enclose_all_in_quotes) then
            write(me%iunit,fmt='(A)',advance='NO',iostat=istat) me%quote
        end if

        select type (val)
        type is (integer(ip))
            if (present(int_fmt)) then
                ifmt = trim(adjustl(int_fmt))
            else
                ifmt = default_int_fmt
            end if
            write(int_val,fmt=ifmt,iostat=istat) val
            write(me%iunit,fmt='(A)',advance='NO',iostat=istat) trim(adjustl(int_val))
        type is (real(wp))
            if (present(real_fmt)) then
                rfmt = trim(adjustl(real_fmt))
            else
                rfmt = default_real_fmt
            end if
            write(real_val,fmt=rfmt,iostat=istat) val
            write(me%iunit,fmt='(A)',advance='NO',iostat=istat) trim(adjustl(real_val))
        type is (logical)
            if (val) then
                write(me%iunit,fmt='(A)',advance='NO',iostat=istat) 'T'   !TODO make these user-defined strings
            else
                write(me%iunit,fmt='(A)',advance='NO',iostat=istat) 'F'
            end if
        type is (character(len=*))
            if (me%enclose_strings_in_quotes .and. .not. me%enclose_all_in_quotes) &
                write(me%iunit,fmt='(A)',advance='NO',iostat=istat) me%quote
            if (present(trim_str)) then
                trimstr = trim_str
            else
                trimstr = .false.
            end if
            if (trimstr) then
                write(me%iunit,fmt='(A)',advance='NO',iostat=istat) trim(val)
            else
                write(me%iunit,fmt='(A)',advance='NO',iostat=istat) val
            end if
            if (me%enclose_strings_in_quotes .and. .not. me%enclose_all_in_quotes) &
                write(me%iunit,fmt='(A)',advance='NO',iostat=istat) me%quote
        type is (csv_string)
            if (me%enclose_strings_in_quotes .and. .not. me%enclose_all_in_quotes) &
                write(me%iunit,fmt='(A)',advance='NO',iostat=istat) me%quote
            if (present(trim_str)) then
                trimstr = trim_str
            else
                trimstr = .false.
            end if
            if (trimstr) then
                write(me%iunit,fmt='(A)',advance='NO',iostat=istat) trim(val%str)
            else
                write(me%iunit,fmt='(A)',advance='NO',iostat=istat) val%str
            end if
            if (me%enclose_strings_in_quotes .and. .not. me%enclose_all_in_quotes) &
                write(me%iunit,fmt='(A)',advance='NO',iostat=istat) me%quote
        class default
            if (me%verbose) write(error_unit,'(A)') &
                    'Error: cannot write unknown variable type to CSV file.'
        end select

        if (me%enclose_all_in_quotes) then
            write(me%iunit,fmt='(A)',advance='NO',iostat=istat) me%quote
        end if
        if (me%icol<me%n_cols) write(me%iunit,fmt='(A)',advance='NO',iostat=istat) me%delimiter

    else
        if (me%verbose) write(error_unit,'(A)') &
                'Error: cannot write more cells to the current row.'
    end if

    end subroutine add_cell
!*****************************************************************************************

!*****************************************************************************************
!>
!  Add a vector to a CSV file. Each element is added as a cell to the current line.
!
!@warning There is some bug here with GFortran 6.1 when `val` is a character string.

    subroutine add_vector(me,val,int_fmt,real_fmt,trim_str)

    implicit none

    class(csv_file),intent(inout) :: me
    class(*),dimension(:),intent(in) :: val  !! the values to add
    character(len=*),intent(in),optional :: int_fmt !! format string for integers
    character(len=*),intent(in),optional :: real_fmt !! format string for reals
    logical,intent(in),optional :: trim_str !! to trim the string

    integer :: i !! counter

    do i=1,size(val)
        call me%add(val(i),int_fmt,real_fmt,trim_str)
    end do

    end subroutine add_vector
!*****************************************************************************************

!*****************************************************************************************
!>
!  Add a matrix to a CSV file. Each row is added as a new line.
!  Line breaks are added at the end of each line (in this way it
!  differs from the other `add` routines).

    subroutine add_matrix(me,val,int_fmt,real_fmt,trim_str)

    implicit none

    class(csv_file),intent(inout) :: me
    class(*),dimension(:,:),intent(in) :: val  !! the values to add
    character(len=*),intent(in),optional :: int_fmt !! format string for integers
    character(len=*),intent(in),optional :: real_fmt !! format string for reals
    logical,intent(in),optional :: trim_str !! to trim the string

    integer :: i !! counter

    ! add each row:
    do i=1,size(val,1)
        call me%add(val(i,:),int_fmt,real_fmt,trim_str)
        call me%next_row()
    end do

    end subroutine add_matrix
!*****************************************************************************************

!*****************************************************************************************
!>
!  Advance to the next row in the CSV file
!  (write any blank cells that are necessary to finish the row)

    subroutine next_row(me)

    implicit none

    class(csv_file),intent(inout) :: me

    integer :: i  !! counter
    integer :: n  !! number of blank cells to write

    if (me%icol>0) then
        n = me%n_cols - me%icol
        do i=1,n
            if (i==n) then !no trailing delimiter
                if (me%enclose_strings_in_quotes) then
                    write(me%iunit,'(A)',advance='NO') me%quote//me%quote
                end if
            else
                if (me%enclose_strings_in_quotes) then
                    write(me%iunit,'(A)',advance='NO') me%quote//me%quote//me%delimiter
                else
                    write(me%iunit,'(A)',advance='NO') me%delimiter
                end if
            end if
        end do
        write(me%iunit,'(A)') '' ! new line
    end if

    me%icol = 0  ! this row is finished

    end subroutine next_row
!*****************************************************************************************

!*****************************************************************************************
!>
!  Returns the header as a `type(csv_string)` array.
!  (`read` must have already been called to read the file).

    subroutine get_header_csv_str(me,header,status_ok)

    implicit none

    class(csv_file),intent(inout) :: me
    type(csv_string),dimension(:),allocatable,intent(out) :: header
    logical,intent(out) :: status_ok

    integer :: i !! column counter

    if (allocated(me%header)) then

        allocate(header(me%n_cols))
        do i=1,me%n_cols
            header(i) = me%header(i)
        end do
        status_ok = .false.

    else
        if (me%verbose) write(error_unit,'(A)') 'Error: no header in class.'
        status_ok = .false.
    end if

    end subroutine get_header_csv_str
!*****************************************************************************************

!*****************************************************************************************
!>
!  Returns the header as a `character(len=*)` array.
!  (`read` must have already been called to read the file).

    subroutine get_header_str(me,header,status_ok)

    implicit none

    class(csv_file),intent(inout) :: me
    character(len=*),dimension(:),allocatable,intent(out) :: header
    logical,intent(out) :: status_ok

    integer :: i !! column counter

    if (allocated(me%header)) then

        allocate(header(me%n_cols))
        do i=1,me%n_cols
            header(i) = me%header(i)%str
        end do
        status_ok = .false.

    else
        if (me%verbose) write(error_unit,'(A)') 'Error: no header in class.'
        status_ok = .false.
    end if

    end subroutine get_header_str
!*****************************************************************************************

!*****************************************************************************************
!>
!  Returns a `character(len=*)` array containing the csv data
!  (`read` must have already been called to read the file).

    subroutine get_csv_data_as_str(me,csv_data,status_ok)

    implicit none

    class(csv_file),intent(inout) :: me
    character(len=*),dimension(:,:),allocatable,intent(out) :: csv_data  !! the data
    logical,intent(out) :: status_ok  !! status flag

    integer :: i !! row counter
    integer :: j !! column counter

    if (allocated(me%csv_data)) then
        ! size the output array:
        allocate(csv_data(me%n_rows,me%n_cols))
        ! convert each element to a string:
        do concurrent (i=1:me%n_rows)
            do concurrent (j=1:me%n_cols)
                csv_data(i,j) = me%csv_data(i,j)%str
            end do
        end do
        status_ok = .true.
    else
        if (me%verbose) write(error_unit,'(A,1X,I5)') 'Error: class has not been initialized'
        status_ok = .false.
    end if

    end subroutine get_csv_data_as_str
!*****************************************************************************************

!*****************************************************************************************
!>
!  Convert a string to a `real(wp)`

    pure elemental subroutine to_real(str,val,status_ok)

    implicit none

    character(len=*),intent(in) :: str
    real(wp),intent(out) :: val
    logical,intent(out) :: status_ok

    integer :: istat  !! read `iostat` error code

    read(str,fmt=*,iostat=istat) val
    if (istat==0) then
        status_ok = .true.
    else
        status_ok = .false.
        val = zero
    end if

    end subroutine to_real
!*****************************************************************************************

!*****************************************************************************************
!>
!  Convert a string to a `integer(ip)`

    pure elemental subroutine to_integer(str,val,status_ok)

    implicit none

    character(len=*),intent(in) :: str
    integer(ip),intent(out) :: val
    logical,intent(out) :: status_ok

    integer :: istat  !! read `iostat` error code

    read(str,fmt=default_int_fmt,iostat=istat) val
    if (istat==0) then
        status_ok = .true.
    else
        status_ok = .false.
        val = 0
    end if

    end subroutine to_integer
!*****************************************************************************************

!*****************************************************************************************
!>
!  Convert a string to a `logical`
!
!  * Evaluates to `.true.`  for strings ['1','t','true','.true.']
!  * Evaluates to `.false.` for strings ['0','f','false','.false.']
!
!  The string match is not case sensitive.

    pure elemental subroutine to_logical(str,val,status_ok)

    implicit none

    character(len=*),intent(in) :: str
    logical,intent(out) :: val
    logical,intent(out) :: status_ok

    character(len=:),allocatable :: tmp

    ! True and False options (all lowercase):
    character(len=*),dimension(4),parameter :: true_str  = ['1     ',&
                                                            't     ',&
                                                            'true  ',&
                                                            '.true.']
    character(len=*),dimension(4),parameter :: false_str = ['0      ',&
                                                            'f      ',&
                                                            'false  ',&
                                                            '.false.']

    tmp = lowercase_string(str)
    if ( any(tmp==true_str) ) then
        val = .true.
        status_ok = .true.
    elseif ( any(tmp==false_str) ) then
        val = .false.
        status_ok = .true.
    else
        val = .false.
        status_ok = .false.
    end if

    end subroutine to_logical
!*****************************************************************************************

!*****************************************************************************************
!>
!  Returns an array indicating the variable type of each columns.
!
!@note The first element in the column is used to determine the type.

    subroutine variable_types(me,itypes,status_ok)

    implicit none

    class(csv_file),intent(inout) :: me
    integer,dimension(:),allocatable,intent(out) :: itypes
    logical,intent(out) :: status_ok

    integer :: i !! counter

    if (allocated(me%csv_data)) then
        allocate(itypes(me%n_cols))
        do i=1,me%n_cols
            call infer_variable_type(me%csv_data(1,i)%str,itypes(i))
        end do
    else
        if (me%verbose) write(error_unit,'(A,1X,I5)') 'Error: class has not been initialized'
        status_ok = .false.
    end if

    end subroutine variable_types
!*****************************************************************************************

!*****************************************************************************************
!>
!  Infers the variable type, assuming the following precedence:
!
!  * integer
!  * double
!  * logical
!  * character

    subroutine infer_variable_type(str,itype)

    implicit none

    character(len=*),intent(in) :: str
    integer,intent(out) :: itype

    real(wp)    :: rval      !! a real value
    integer(ip) :: ival      !! an iteger value
    logical     :: lval      !! a logical value
    logical     :: status_ok !! status flag

    call to_integer(str,ival,status_ok)
    if (status_ok) then
        itype = csv_type_integer
        return
    end if

    call to_real(str,rval,status_ok)
    if (status_ok) then
        itype = csv_type_double
        return
    end if

    call to_logical(str,lval,status_ok)
    if (status_ok) then
        itype = csv_type_logical
        return
    end if

    ! default is string:
    itype = csv_type_string

    end subroutine infer_variable_type
!*****************************************************************************************

!*****************************************************************************************
!>
!  Get an individual value from the `csv_data` structure in the CSV class.
!
!  The output `val` can be an `integer(ip)`, `real(wp)`,
!  `logical`, or `character(len=*)` variable.

    subroutine csv_get_value(me,row,col,val,status_ok)

    implicit none

    class(csv_file),intent(inout) :: me
    integer,intent(in)   :: row !! row number
    integer,intent(in)   :: col !! column number
    class(*),intent(out) :: val !! the returned value
    logical,intent(out)  :: status_ok !! status flag

    select type (val)
    type is (integer(ip))
        call to_integer(me%csv_data(row,col)%str,val,status_ok)
    type is (real(wp))
        call to_real(me%csv_data(row,col)%str,val,status_ok)
    type is (logical)
        call to_logical(me%csv_data(row,col)%str,val,status_ok)
    type is (character(len=*))
        status_ok = .true.
        if (allocated(me%csv_data(row,col)%str)) then
            val = me%csv_data(row,col)%str
        else
            val = ''
        end if
    type is (csv_string)
        status_ok = .true.
        val = me%csv_data(row,col)
    class default
        status_ok = .false.
    end select

    end subroutine csv_get_value
!*****************************************************************************************

!*****************************************************************************************
!>
!  Return a column from a CSV file vector.
!
!@note This routine requires that the `r` array already be allocated.
!      This is because Fortran doesn't want to allow to you pass
!      a non-polymorphic variable into a routine with a dummy variable
!      with `class(*),dimension(:),allocatable,intent(out)` attributes.

    subroutine get_column(me,icol,r,status_ok)

    implicit none

    class(csv_file),intent(inout) :: me
    integer,intent(in) :: icol  !! column number
    class(*),dimension(:),intent(out) :: r  !! assumed to have been allocated to
                                            !! the correct size by the caller.
                                            !! (n_rows)
    logical,intent(out) :: status_ok  !! status flag

    integer :: i !! counter

    ! we know the data is allocated, since that
    ! was checked by the calling routines.

    if (me%n_cols>=icol .and. icol>0) then

        do i=1,me%n_rows  ! row loop

            call me%csv_get_value(i,icol,r(i),status_ok)

            if (.not. status_ok) then
                select type (r)
                ! note: character conversion can never fail, so not
                ! checking for that here. also we know it is real,
                ! integer, or logical at this point.
                type is (integer(ip))
                    if (me%verbose) write(error_unit,'(A)') &
                        'Error converting string to integer: '//trim(me%csv_data(i,icol)%str)
                    r(i) = 0
                type is (real(wp))
                    if (me%verbose) write(error_unit,'(A)') &
                        'Error converting string to real: '//trim(me%csv_data(i,icol)%str)
                    r(i) = zero
                type is (logical)
                    if (me%verbose) write(error_unit,'(A)') &
                        'Error converting string to logical: '//trim(me%csv_data(i,icol)%str)
                    r(i) = .false.
                end select
            end if

        end do

    else
        if (me%verbose) write(error_unit,'(A,1X,I5)') 'Error: invalid column number: ',icol
        status_ok = .false.
    end if

    end subroutine get_column
!*****************************************************************************************

!*****************************************************************************************
!>
!  Return a column from a CSV file as a `real(wp)` vector.

    subroutine get_real_column(me,icol,r,status_ok)

    implicit none

    class(csv_file),intent(inout) :: me
    integer,intent(in) :: icol  !! column number
    real(wp),dimension(:),allocatable,intent(out) :: r
    logical,intent(out) :: status_ok

    if (allocated(me%csv_data)) then
        allocate(r(me%n_rows))  ! size the output vector
        call me%get_column(icol,r,status_ok)
    else
        if (me%verbose) write(error_unit,'(A,1X,I5)') 'Error: class has not been initialized'
        status_ok = .false.
    end if

    end subroutine get_real_column
!*****************************************************************************************

!*****************************************************************************************
!>
!  Return a column from a CSV file as a `integer(ip)` vector.

    subroutine get_integer_column(me,icol,r,status_ok)

    implicit none

    class(csv_file),intent(inout) :: me
    integer,intent(in) :: icol  !! column number
    integer(ip),dimension(:),allocatable,intent(out) :: r
    logical,intent(out) :: status_ok

    if (allocated(me%csv_data)) then
        allocate(r(me%n_rows))  ! size the output vector
        call me%get_column(icol,r,status_ok)
    else
        if (me%verbose) write(error_unit,'(A,1X,I5)') 'Error: class has not been initialized'
        status_ok = .false.
    end if

    end subroutine get_integer_column
!*****************************************************************************************

!*****************************************************************************************
!>
!  Convert a column from a `csv_string` matrix to a `logical` vector.

    subroutine get_logical_column(me,icol,r,status_ok)

    implicit none

    class(csv_file),intent(inout) :: me
    integer,intent(in) :: icol  !! column number
    logical,dimension(:),allocatable,intent(out) :: r
    logical,intent(out) :: status_ok

    if (allocated(me%csv_data)) then
        allocate(r(me%n_rows))  ! size the output vector
        call me%get_column(icol,r,status_ok)
    else
        if (me%verbose) write(error_unit,'(A,1X,I5)') 'Error: class has not been initialized'
        status_ok = .false.
    end if

    end subroutine get_logical_column
!*****************************************************************************************

!*****************************************************************************************
!>
!  Convert a column from a `csv_string` matrix to a `character(len=*)` vector.

    subroutine get_character_column(me,icol,r,status_ok)

    implicit none

    class(csv_file),intent(inout) :: me
    integer,intent(in) :: icol  !! column number
    character(len=*),dimension(:),allocatable,intent(out) :: r
    logical,intent(out) :: status_ok

    if (allocated(me%csv_data)) then
        allocate(r(me%n_rows))  ! size the output vector
        call me%get_column(icol,r,status_ok)
    else
        if (me%verbose) write(error_unit,'(A,1X,I5)') 'Error: class has not been initialized'
        status_ok = .false.
    end if

    end subroutine get_character_column
!*****************************************************************************************

!*****************************************************************************************
!>
!  Convert a column from a `csv_string` matrix to a `type(csv_string)` vector.

    subroutine get_csv_string_column(me,icol,r,status_ok)

    implicit none

    class(csv_file),intent(inout) :: me
    integer,intent(in) :: icol  !! column number
    type(csv_string),dimension(:),allocatable,intent(out) :: r
    logical,intent(out) :: status_ok

    if (allocated(me%csv_data)) then
        allocate(r(me%n_rows))  ! size the output vector
        call me%get_column(icol,r,status_ok)
    else
        if (me%verbose) write(error_unit,'(A,1X,I5)') 'Error: class has not been initialized'
        status_ok = .false.
    end if

    end subroutine get_csv_string_column
!*****************************************************************************************

!*****************************************************************************************
!>
!  Tokenize a line from a CSV file. The result is an array of `csv_string` types.
!
!### Notes
!  * Quotes are removed if the entire cell is contained in quotes.
!
!@warning It does not account for delimiters in quotes
!         (these are treated as a new cell). Need to fix!

    subroutine tokenize_csv_line(me,line,cells)

    implicit none

    class(csv_file),intent(inout) :: me
    character(len=*),intent(in) :: line
    type(csv_string),dimension(:),allocatable,intent(out) :: cells

    integer :: i !! counter
    character(len=:),allocatable :: tmp !! a temp string with whitespace removed
    integer :: n !! length of compressed string

    call split(line,me%delimiter,me%chunk_size,cells)

    ! remove quotes if present:
    do i = 1, size(cells)

        ! remove whitespace from the string:
        tmp = trim(adjustl(cells(i)%str))
        n = len(tmp)

        if (n>1) then
            ! if the first and last non-blank character is
            ! a quote, then remove them and replace with what
            ! is inside the quotes. Otherwise, leave it as is.
            if (tmp(1:1)==me%quote .and. tmp(n:n)==me%quote) then
                if (n>2) then
                    cells(i)%str = tmp(2:n-1)  ! remove the quotes
                else
                    cells(i)%str = ''  ! empty string
                end if
            end if
        end if

    end do

    end subroutine tokenize_csv_line
!*****************************************************************************************

!*****************************************************************************************
!>
!  Returns the number of lines in a text file.
!
!@note It rewinds the file back to the beginning when finished.

    function number_of_lines_in_file(iunit) result(n_lines)

    implicit none

    integer,intent(in)  :: iunit   !! the file unit number
                                     !! (assumed to be open)
    integer :: n_lines   !! the number of lines in the file

    character(len=1) :: tmp
    integer :: istat

    rewind(iunit)
    n_lines = 0
    do
        read(iunit,fmt='(A1)',iostat=istat) tmp
        if (is_iostat_end(istat)) exit
        n_lines = n_lines + 1
    end do
    rewind(iunit)

    end function number_of_lines_in_file
!*****************************************************************************************

!*****************************************************************************************
!>
!  Reads the next line from a file.

    subroutine read_line_from_file(me,iunit,line)

    implicit none

    class(csv_file),intent(in) :: me
    integer,intent(in) :: iunit
    character(len=:),allocatable,intent(out) :: line

    integer :: nread  !! character count specifier for read statement
    integer :: istat  !! file read io status flag
    character(len=me%chunk_size) :: buffer !! the file read buffer

    nread  = 0
    buffer = ''
    line   = ''

    do
        ! read in the next block of text from the line:
        read(iunit,fmt='(A)',advance='NO',size=nread,iostat=istat) buffer
        if (IS_IOSTAT_END(istat) .or. IS_IOSTAT_EOR(istat)) then
            ! add the last block of text before the end of record
            if (nread>0) line = line//buffer(1:nread)
            exit
        elseif (istat==0) then ! all the characters were read
            line = line//buffer  ! add this block of text to the string
        else  ! some kind of error
            error stop 'Read error.'
        end if
    end do

    end subroutine read_line_from_file
!*****************************************************************************************

!*****************************************************************************************
!>
!  Split a character string using a token.
!  This routine is inspired by the Python split function.
!
!### Example
!````Fortran
!   type(csv_file) :: f
!   character(len=:),allocatable :: s
!   type(csv_string),dimension(:),allocatable :: vals
!   s = '1,2,3,4,5'
!   vals = f%split(s,',')
!````
!
!@warning Doesn't seem to work for `len(token)>1`
!
!@warning Does not account for tokens contained within quotes string !!!

    pure subroutine split(str,token,chunk_size,vals)

    implicit none

    character(len=*),intent(in)  :: str
    character(len=*),intent(in)  :: token
    integer,intent(in)           :: chunk_size  !! for expanding vectors
    type(csv_string),dimension(:),allocatable,intent(out) :: vals

    integer :: i
    integer :: len_str
    integer :: len_token  !! length of the token
    integer :: n_tokens   !! number of tokens
    integer :: i1         !! index
    integer :: i2         !! index
    integer :: j          !! counters
    character(len=:),allocatable :: temp
    integer,dimension(:),allocatable :: itokens

    temp      = str         ! make a copy of the string
    len_token = len(token)  ! length of the token
    n_tokens  = 0           ! initialize the number of token counter
    j         = 0           ! length of string removed

    !first, count the number of times the token appears in the string
    do
        len_str = len(temp)    ! length of the string
        i = index(temp,token)  ! location of the next token
        if (i<=0) exit         ! no more tokens found
        call expand_vector(itokens,n_tokens,chunk_size,i+j)  ! save the token location
        if (i+len_token>len_str) exit  ! if the last bit of the string is a token
        j = j + i
        temp = temp(i+len_token:len_str)  !remove previously scanned part of string
    end do
    call expand_vector(itokens,n_tokens,chunk_size,finished=.true.)  ! resize the vector

    allocate(vals(n_tokens+1))

    if (n_tokens>0) then

        len_str = len(str)

        i1 = 1
        i2 = itokens(1)-1
        if (n_tokens>1) then
            vals(1)%str = str(i1:i2)
        else
            vals(1)%str = ''  !the first character is a token
        end if

        !      1 2 3
        !    'a,b,c,d'

        do i=2,n_tokens
            i1 = itokens(i-1)+len_token
            i2 = itokens(i)-1
            if (i2>=i1) then
                vals(i)%str = str(i1:i2)
            else
                vals(i)%str = ''  !empty element (e.g., 'abc,,def')
            end if
        end do

        i1 = itokens(n_tokens) + len_token
        i2 = len_str
        if (itokens(n_tokens)+len_token<=len_str) then
            vals(n_tokens+1)%str = str(i1:i2)
        else
            vals(n_tokens+1)%str = ''  !the last character was a token
        end if

    else
        !no tokens present, so just return the original string:
        vals(1)%str = str
    end if

    end subroutine split
!*****************************************************************************************

!*****************************************************************************************
    end module csv_module
!*****************************************************************************************
